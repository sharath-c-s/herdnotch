import Darwin
import Dispatch
import Foundation

/// Unix socket server that holds each PermissionRequest hook connection open until the app replies.
///
/// Thread-safety: all state lives on one serial queue; callbacks run on that queue, so keep them short
/// and hop to another actor inside them. Tokens are unique per server instance and never reused.
public final class ApprovalSocketServer: @unchecked Sendable {
    private struct Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        /// True once the request line was decoded and handed to `onRequest`.
        var delivered = false
    }

    private let path: String
    private let queue = DispatchQueue(label: "herdnotch.approval-socket")
    private var listener: DispatchSourceRead?
    private var connections: [UInt64: Connection] = [:]
    private var nextToken: UInt64 = 1
    /// True once this instance bound `path`, so `stop()` never unlinks another instance's socket.
    private var didBind = false
    private var onRequest: (@Sendable (UInt64, HookRequest) -> Void)?
    private var onClose: (@Sendable (UInt64) -> Void)?

    /// A connection that has not sent a full request line within this many seconds is closed.
    private let requestLineTimeout: TimeInterval

    public init(path: String, requestLineTimeout: TimeInterval = 5) {
        self.path = path
        self.requestLineTimeout = requestLineTimeout
    }

    /// Binds and starts accepting; throws if the path is too long, the socket cannot be created, or a live
    /// server already answers on `path`.
    public func start(
        onRequest: @escaping @Sendable (UInt64, HookRequest) -> Void,
        onClose: @escaping @Sendable (UInt64) -> Void
    ) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw HerdrError.socketUnavailable("path longer than \(capacity - 1) bytes: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            guard !Self.isLive(&address) else {
                throw HerdrError.socketUnavailable("another instance is already listening on \(path)")
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("socket()") }
        var ok = false
        var didBindHere = false
        defer {
            if !ok {
                Darwin.close(fd)
                if didBindHere { unlink(path) }
            }
        }

        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else { throw Self.failure("bind(\(path))") }
        didBindHere = true
        guard chmod(path, 0o600) == 0 else { throw Self.failure("chmod(\(path))") }
        guard listen(fd, 16) == 0 else { throw Self.failure("listen()") }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) != -1 else { throw Self.failure("fcntl()") }
        ok = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listenFD: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        queue.sync {
            self.onRequest = onRequest
            self.onClose = onClose
            self.listener = source
            self.didBind = true
        }
        source.resume()
    }

    /// Writes `output` plus a newline and closes the connection; empty output means passthrough.
    ///
    /// Unknown or already-closed tokens are ignored.
    public func reply(token: UInt64, output: Data) {
        queue.async { [self] in
            guard let connection = connections.removeValue(forKey: token) else { return }
            var line = output
            line.append(UInt8(ascii: "\n"))
            Self.writeAll(connection.fd, line)
            connection.source.cancel()
        }
    }

    /// Closes every connection and removes the socket file if this instance bound it.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.source.cancel() }
            connections.removeAll()
            onRequest = nil
            onClose = nil
            if didBind { unlink(path) }
            didBind = false
        }
    }

    // MARK: - Queue-confined

    private func acceptPending(listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

            let token = nextToken
            nextToken += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readable(token: token) }
            source.setCancelHandler { Darwin.close(fd) }
            connections[token] = Connection(fd: fd, source: source)
            source.resume()
            queue.asyncAfter(deadline: .now() + requestLineTimeout) { [weak self] in
                guard let self, let stale = connections[token], !stale.delivered else { return }
                rejectWithPassthrough(token: token, connection: stale)
            }
        }
    }

    private func readable(token: UInt64) {
        guard var connection = connections[token] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = recv(connection.fd, &chunk, chunk.count, 0)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        if count <= 0 {
            // Peer closed or errored: nothing can be replied to anymore.
            connections.removeValue(forKey: token)
            connection.source.cancel()
            if connection.delivered { onClose?(token) }
            return
        }
        guard !connection.delivered else { return }

        connection.buffer.append(contentsOf: chunk[0..<count])
        if let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(connection.buffer[connection.buffer.startIndex..<newline])
            if let request = try? JSONDecoder().decode(HookRequest.self, from: line) {
                connection.delivered = true
                connection.buffer = Data()
                connections[token] = connection
                onRequest?(token, request)
            } else {
                rejectWithPassthrough(token: token, connection: connection)
            }
        } else if connection.buffer.count > NDJSONFramer.defaultMaximumLineBytes {
            rejectWithPassthrough(token: token, connection: connection)
        } else {
            connections[token] = connection
        }
    }

    private func rejectWithPassthrough(token: UInt64, connection: Connection) {
        connections.removeValue(forKey: token)
        Self.writeAll(connection.fd, Data("\n".utf8))
        connection.source.cancel()
    }

    /// Best-effort blocking-style write on a non-blocking fd, giving up after 2 s of no progress.
    private static func writeAll(_ fd: Int32, _ data: Data) {
        var offset = 0
        data.withUnsafeBytes { raw in
            while offset < raw.count {
                let sent = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if sent > 0 { offset += sent; continue }
                if errno == EINTR { continue }
                guard errno == EAGAIN else { return }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 2000) <= 0 { return }
            }
        }
    }

    /// True when something accepts connections on the socket address.
    private static func isLive(_ address: inout sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private static func failure(_ what: String) -> HerdrError {
        .socketUnavailable("\(what) failed: \(String(cString: strerror(errno)))")
    }
}
