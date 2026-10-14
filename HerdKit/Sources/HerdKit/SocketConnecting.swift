import Darwin
import Foundation

// MARK: - Errors

/// Every failure mode of talking to a herdr server.
///
/// Split by cause rather than by call site because the UI reacts differently to each: a missing
/// socket means "that session is not running" and is expected, a `server` error means herdr answered
/// and disagreed with us, and a `decode` error means HerdKit's models have drifted from herdr's wire
/// format and needs a code change.
public enum HerdrError: Error, Sendable, Equatable {
    /// No usable socket at the given path: the file is absent, is not a socket, or nothing is
    /// listening on it. This is the normal state of a stopped session, whose socket file is left
    /// behind on disk, so it must never be treated as an alarming condition.
    case socketUnavailable(String)
    /// The socket accepted the connection but did not produce a complete response line in time.
    case timeout
    /// The peer spoke something that is not the herdr protocol: closed mid-message, or sent a body
    /// with neither a `result` nor an `error`.
    case protocolError(String)
    /// herdr returned a well-formed error envelope. `code` is herdr's machine-readable code, for
    /// example `invalid_request`.
    case server(code: String, message: String)
    /// A response was valid JSON but did not match the expected shape.
    case decode(String)
}

extension HerdrError: CustomStringConvertible {
    /// Human-readable one-liner, used verbatim as `HerdSession.error` and therefore visible in the
    /// panel. Kept short because it renders in a notch-sized row.
    public var description: String {
        switch self {
        case .socketUnavailable(let detail): "socket unavailable: \(detail)"
        case .timeout: "timed out waiting for herdr"
        case .protocolError(let detail): "protocol error: \(detail)"
        case .server(let code, let message): "herdr error \(code): \(message)"
        case .decode(let detail): "could not decode response: \(detail)"
        }
    }
}

// MARK: - Seams

/// A live byte stream to one herdr server.
///
/// Exists so ``HerdrClient`` and ``HerdrDiscovery`` can be tested against scripted byte chunks
/// instead of real sockets, which is what makes the framing and failure paths testable at all.
///
/// Thread-safety: implementations are `Sendable` and may be handed between threads, but a single
/// connection carries one request/response exchange and is not designed for concurrent use.
public protocol HerdrConnection: AnyObject, Sendable {
    /// Writes all of `data`, retrying short writes.
    ///
    /// - Parameter data: Bytes to send, newline included by the caller.
    /// - Throws: ``HerdrError/timeout`` if the send timeout elapses, ``HerdrError/socketUnavailable``
    ///   on any other write failure.
    func write(_ data: Data) throws

    /// Reads whatever bytes are available, blocking up to `timeout`.
    ///
    /// - Parameter timeout: Maximum time to wait for the first byte. A non-positive value means the
    ///   caller's budget is already gone, and must be reported as ``HerdrError/timeout`` without reading:
    ///   callers pass `Deadline.remaining`, so an implementation that quietly granted itself a moment
    ///   anyway would make the advertised timeout an upper bound in name only.
    /// - Returns: The bytes read, or an empty `Data` when the peer closed the connection (EOF).
    /// - Throws: ``HerdrError/timeout`` if nothing arrived in time or the budget is already exhausted,
    ///   ``HerdrError/socketUnavailable`` on any other read failure.
    func read(timeout: TimeInterval) throws -> Data

    /// Releases the underlying descriptor. Safe to call more than once.
    func close()
}

/// Opens ``HerdrConnection`` values by socket path.
///
/// The single injection point for tests: a fake connector can succeed for some paths and fail for
/// others, which is how the "one dead session" and "stopped session" behaviours are exercised
/// without starting or stopping a real herdr server.
public protocol SocketConnecting: Sendable {
    /// Connects to a Unix domain socket.
    ///
    /// - Parameters:
    ///   - path: Absolute filesystem path of the socket.
    ///   - timeout: Budget for establishing the connection and the default I/O deadline.
    /// - Returns: An open connection.
    /// - Throws: ``HerdrError/socketUnavailable`` when nothing is listening, ``HerdrError/timeout``
    ///   when the connect attempt exceeds `timeout`.
    func connect(path: String, timeout: TimeInterval) throws -> HerdrConnection
}

// MARK: - Real implementation

/// Connects to herdr over `AF_UNIX` / `SOCK_STREAM` using the Darwin socket API.
///
/// The connect is performed non-blocking with an explicit `poll()` deadline, and both directions
/// carry `SO_RCVTIMEO` / `SO_SNDTIMEO`. This matters more than anything else in the file: a stopped
/// herdr session leaves its socket file on disk, so connecting to a dead socket is the *normal*
/// case, not an edge case. A blocking connect that could stall would freeze the panel's poll loop
/// every time a session is stopped.
public struct UnixSocketConnector: SocketConnecting {
    /// Creates a connector. Holds no state; one instance can serve every session.
    public init() {}

    /// Opens a connection, failing fast when no server is listening.
    ///
    /// - Parameters:
    ///   - path: Absolute path of a `herdr.sock`. Must fit in `sockaddr_un.sun_path` (104 bytes).
    ///   - timeout: Upper bound on the connect attempt, also installed as the socket's send and
    ///     receive timeout.
    /// - Returns: An open connection owning its file descriptor.
    /// - Throws: ``HerdrError/socketUnavailable`` if the path is too long, the descriptor cannot be
    ///   created, or the connect is refused; ``HerdrError/timeout`` if the connect does not complete
    ///   within `timeout`.
    public func connect(path: String, timeout: TimeInterval) throws -> HerdrConnection {
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

        // One monotonic budget for the whole connect, so an EINTR retry resumes against the original
        // deadline instead of restarting the clock and letting a stream of signals extend the wait
        // indefinitely.
        let deadline = Deadline(after: timeout)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrError.socketUnavailable("socket() failed: \(Self.errnoText(errno))")
        }
        var owned = true
        defer { if owned { Darwin.close(fd) } }

        // Writing to a socket whose peer has closed raises SIGPIPE, whose default disposition is to
        // terminate the process. That is not hypothetical here: a herdr server stopping between the
        // liveness probe and the request is the ordinary case, and a probe against a closed peer was
        // observed exiting with status 141 (128 + SIGPIPE). SO_NOSIGPIPE turns that into an EPIPE
        // return from send(), which the write path already reports as socketUnavailable.
        //
        // Set per socket rather than by ignoring SIGPIPE process-wide, because HerdKit is a library
        // and must not mutate its host's signal disposition.
        var suppressSigPipe: Int32 = 1
        try Self.check("setsockopt(SO_NOSIGPIPE)", path: path) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigPipe, socklen_t(MemoryLayout<Int32>.size))
        }

        // These are checked rather than best-effort because an unnoticed failure here would make the
        // timeout guarantee a lie: a socket with no SO_RCVTIMEO blocks forever, and this library's
        // whole contract is that a dead session fails fast.
        try Self.setTimeout(fd, option: SO_RCVTIMEO, seconds: timeout, path: path)
        try Self.setTimeout(fd, option: SO_SNDTIMEO, seconds: timeout, path: path)

        // Non-blocking connect plus poll: SO_RCVTIMEO does not bound connect(), and a socket whose
        // listener has gone away (or whose accept backlog is full) can otherwise block indefinitely.
        let originalFlags = try Self.check("fcntl(F_GETFL)", path: path) { fcntl(fd, F_GETFL, 0) }
        try Self.check("fcntl(F_SETFL, O_NONBLOCK)", path: path) {
            fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let connectErrno = errno
            // EINTR on a non-blocking connect does not abort the attempt: POSIX says the connection
            // continues asynchronously, so it is handled exactly like EINPROGRESS by polling.
            guard connectErrno == EINPROGRESS || connectErrno == EINTR else {
                throw HerdrError.socketUnavailable("connect(\(path)) failed: \(Self.errnoText(connectErrno))")
            }
            try Self.awaitWritable(fd, path: path, deadline: deadline)

            var pendingError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            try Self.check("getsockopt(SO_ERROR)", path: path) {
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &length)
            }
            guard pendingError == 0 else {
                throw HerdrError.socketUnavailable("connect(\(path)) failed: \(Self.errnoText(pendingError))")
            }
        }

        try Self.check("fcntl(F_SETFL, restore)", path: path) { fcntl(fd, F_SETFL, originalFlags) }
        owned = false
        return UnixSocketConnection(fd: fd)
    }

    /// Polls for the connect to complete, retrying `EINTR` against the shared deadline.
    ///
    /// Retrying against `deadline` rather than re-passing the original timeout is the point: a
    /// process taking regular signals would otherwise reset the wait on every interruption and never
    /// time out at all.
    ///
    /// - Parameters:
    ///   - fd: The connecting descriptor.
    ///   - path: Socket path, for error messages.
    ///   - deadline: The connect's overall budget.
    /// - Throws: ``HerdrError/timeout`` when the budget runs out, ``HerdrError/socketUnavailable``
    ///   when `poll` itself fails.
    private static func awaitWritable(_ fd: Int32, path: String, deadline: Deadline) throws {
        while true {
            guard !deadline.hasExpired else { throw HerdrError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, deadline.pollMilliseconds)
            if ready > 0 { return }
            if ready == 0 { throw HerdrError.timeout }
            if errno == EINTR { continue }
            throw HerdrError.socketUnavailable("poll(\(path)) failed: \(errnoText(errno))")
        }
    }

    /// Installs a `timeval` timeout on one socket option, clamped so a zero timeout does not turn
    /// into "block forever" (which is what `SO_RCVTIMEO` of 0 means).
    ///
    /// - Throws: ``HerdrError/socketUnavailable`` if the option cannot be set.
    private static func setTimeout(
        _ fd: Int32,
        option: Int32,
        seconds: TimeInterval,
        path: String
    ) throws {
        let clamped = max(0.001, seconds)
        var value = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - Double(Int(clamped))) * 1_000_000)
        )
        try check("setsockopt(\(option == SO_RCVTIMEO ? "SO_RCVTIMEO" : "SO_SNDTIMEO"))", path: path) {
            setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// Runs a syscall and throws if it reports failure.
    ///
    /// - Parameters:
    ///   - label: Syscall name for the error message.
    ///   - path: Socket path, for context.
    ///   - body: The call. Must follow the `-1 means failure, errno explains` convention.
    /// - Returns: The call's non-negative result.
    /// - Throws: ``HerdrError/socketUnavailable`` carrying `errno` as text.
    @discardableResult
    private static func check(
        _ label: String,
        path: String,
        _ body: () -> Int32
    ) throws -> Int32 {
        let result = body()
        guard result != -1 else {
            throw HerdrError.socketUnavailable("\(label) on \(path) failed: \(errnoText(errno))")
        }
        return result
    }

    /// Renders an `errno` value as `strerror` text, for error messages a human has to read.
    fileprivate static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// A connected Unix domain socket owning its file descriptor.
///
/// Thread-safety: the descriptor is guarded by a lock so that `close()` from one thread cannot race
/// a `read` on another. The intended usage is still one exchange per connection on one thread.
private final class UnixSocketConnection: HerdrConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard fd >= 0 else { throw HerdrError.socketUnavailable("write on a closed socket") }
            var offset = 0
            try data.withUnsafeBytes { raw in
                while offset < raw.count {
                    let sent = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if sent > 0 {
                        offset += sent
                        continue
                    }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw HerdrError.timeout }
                    throw HerdrError.socketUnavailable("send() failed: \(UnixSocketConnector.errnoText(errno))")
                }
            }
        }
    }

    func read(timeout: TimeInterval) throws -> Data {
        try lock.withLock {
            guard fd >= 0 else { throw HerdrError.socketUnavailable("read on a closed socket") }
            // An exhausted budget is a timeout, and it is answered as one before any syscall runs. The
            // caller passes `Deadline.remaining`, which reaches zero once connect and write have spent the
            // whole allowance, and the previous `max(0.001, timeout)` turned that into a millisecond the
            // caller had never granted. Short-circuiting here is what makes the advertised timeout an
            // actual upper bound rather than an upper bound plus a phase.
            guard timeout > 0 else { throw HerdrError.timeout }
            try installReceiveTimeout(timeout)

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let received = recv(fd, &buffer, buffer.count, 0)
                if received > 0 { return Data(buffer[0..<received]) }
                if received == 0 { return Data() }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw HerdrError.timeout }
                throw HerdrError.socketUnavailable("recv() failed: \(UnixSocketConnector.errnoText(errno))")
            }
        }
    }

    func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    /// Installs `SO_RCVTIMEO` for one read, tolerating the single failure that is not an option problem.
    ///
    /// Checked rather than best-effort, because a socket with no receive timeout blocks forever and this
    /// library's whole contract is that a dead session fails fast. The check is also what exposed the bug
    /// this method exists to contain, so it stays.
    ///
    /// The tolerated case is a peer that has already closed. Darwin's `sosetopt()` refuses **every** socket
    /// option once a socket is fully shut down, and a Unix stream socket becomes fully shut down the instant
    /// its peer closes, because `soisdisconnected()` raises `SS_CANTRCVMORE` and `SS_CANTSENDMORE` together;
    /// it reports that refusal as `EINVAL`. A herdr server writing its response and closing is the ordinary
    /// end of an exchange, so treating that `EINVAL` as a broken socket discarded a reply that was already
    /// sitting in the receive buffer, and cost the caller a whole session's rows. The hang the check guards
    /// against cannot happen in that state either: a hung-up socket's `recv` returns the buffered bytes and
    /// then EOF without ever blocking.
    ///
    /// The hang-up is confirmed with a zero-timeout `poll` rather than inferred from `errno`, so a genuine
    /// option failure, such as a wrongly sized `timeval`, still throws instead of being waved through.
    ///
    /// - Parameter seconds: Budget for the read, already known to be positive.
    /// - Throws: ``HerdrError/socketUnavailable`` if the option cannot be set for any reason other than the
    ///   peer having hung up.
    private func installReceiveTimeout(_ seconds: TimeInterval) throws {
        // Floored at a millisecond, not because a caller may pass zero (``read(timeout:)`` has already
        // rejected that) but because `SO_RCVTIMEO` reads a zero `timeval` as "block forever", which is the
        // one value that would turn a nearly-expired budget into a hang.
        let clamped = max(0.001, seconds)
        var value = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - Double(Int(clamped))) * 1_000_000)
        )
        guard setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)
        ) != -1 else {
            let failure = errno
            guard Self.peerHasHungUp(fd) else {
                throw HerdrError.socketUnavailable(
                    "setsockopt(SO_RCVTIMEO) failed: \(UnixSocketConnector.errnoText(failure))"
                )
            }
            return
        }
    }

    /// Whether the peer has closed its end, answered immediately.
    ///
    /// - Parameter fd: The connected descriptor.
    /// - Returns: `true` when `poll` reports `POLLHUP`, which on a Unix stream socket means the peer is gone
    ///   and no `recv` on it can block.
    private static func peerHasHungUp(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        return descriptor.revents & Int16(POLLHUP) != 0
    }
}
