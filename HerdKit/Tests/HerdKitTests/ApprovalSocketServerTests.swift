import Foundation
import HerdKit
import Testing

/// Thread-safe capture of server callbacks.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(UInt64, HookRequest)] = []
    private var closed: [UInt64] = []

    func add(_ token: UInt64, _ request: HookRequest) { lock.withLock { requests.append((token, request)) } }
    func close(_ token: UInt64) { lock.withLock { closed.append(token) } }
    var firstRequest: (UInt64, HookRequest)? { lock.withLock { requests.first } }
    var closedTokens: [UInt64] { lock.withLock { closed } }
}

@Suite(.serialized) struct ApprovalSocketServerTests {
    private func tempPath() -> String { "/tmp/hn-\(UUID().uuidString.prefix(8)).sock" }

    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func startServer(_ path: String, _ recorder: Recorder) throws -> ApprovalSocketServer {
        let server = ApprovalSocketServer(path: path)
        try server.start(onRequest: { recorder.add($0, $1) }, onClose: { recorder.close($0) })
        return server
    }

    private func runClient(_ path: String) throws -> Task<Data, Never> {
        let stdin = try Fixture.data("last_input_Bash")
        return Task.detached {
            PermissionHookClient.run(stdin: stdin, socketPath: path, timeout: 10)
        }
    }

    @Test func roundTripRelaysAllowExactly() async throws {
        let path = tempPath()
        let recorder = Recorder()
        let server = try startServer(path, recorder)
        defer { server.stop() }

        let client = try runClient(path)
        #expect(eventually { recorder.firstRequest != nil })
        let (token, request) = try #require(recorder.firstRequest)
        #expect(request.toolName == "Bash")

        let output = HookOutput.render(.allow, for: request)
        server.reply(token: token, output: output)
        #expect(await client.value == output)
    }

    @Test func secondInstanceBacksOffAndLeavesTheSocketAlone() throws {
        let path = tempPath()
        let first = try startServer(path, Recorder())
        defer { first.stop() }
        let second = ApprovalSocketServer(path: path)
        #expect(throws: HerdrError.self) { try second.start(onRequest: { _, _ in }, onClose: { _ in }) }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func passthroughReplyGivesEmptyData() async throws {
        let path = tempPath()
        let recorder = Recorder()
        let server = try startServer(path, recorder)
        defer { server.stop() }

        let client = try runClient(path)
        #expect(eventually { recorder.firstRequest != nil })
        server.reply(token: try #require(recorder.firstRequest).0, output: Data())
        #expect(await client.value.isEmpty)
    }

    @Test func clientDisconnectTriggersOnClose() throws {
        let path = tempPath()
        let recorder = Recorder()
        let server = try startServer(path, recorder)
        defer { server.stop() }

        let connection = try UnixSocketConnector().connect(path: path, timeout: 2)
        var line = try Fixture.data("last_input_Bash").compactedJSONLine()
        line.append(UInt8(ascii: "\n"))
        try connection.write(line)
        #expect(eventually { recorder.firstRequest != nil })
        let token = try #require(recorder.firstRequest).0
        connection.close()
        #expect(eventually { recorder.closedTokens == [token] })
    }

    @Test func invalidRequestGetsPassthrough() throws {
        let path = tempPath()
        let recorder = Recorder()
        let server = try startServer(path, recorder)
        defer { server.stop() }

        let connection = try UnixSocketConnector().connect(path: path, timeout: 2)
        defer { connection.close() }
        try connection.write(Data("not json\n".utf8))
        let reply = try connection.read(timeout: 2)
        #expect(reply == Data("\n".utf8))
        #expect(recorder.firstRequest == nil)
    }

    @Test func silentConnectionIsClosedWithPassthroughAfterTheTimeout() throws {
        let path = tempPath()
        let server = ApprovalSocketServer(path: path, requestLineTimeout: 0.2)
        try server.start(onRequest: { _, _ in }, onClose: { _ in })
        defer { server.stop() }

        let connection = try UnixSocketConnector().connect(path: path, timeout: 2)
        defer { connection.close() }
        let started = Date()
        #expect(try connection.read(timeout: 2) == Data("\n".utf8))
        #expect(Date().timeIntervalSince(started) < 1.5)
        // After the passthrough line the server hangs up: the next read gets no data.
        let eof = try? connection.read(timeout: 1)
        #expect(eof == nil || eof == Data())
    }

    @Test func stopUnlinksSocketFile() throws {
        let path = tempPath()
        let server = try startServer(path, Recorder())
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func staleFileIsReplacedAndSocketIs0600() throws {
        let path = tempPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = try startServer(path, Recorder())
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect((attributes[.type] as? FileAttributeType) == .typeSocket)
    }

    @Test func overlongPathThrows() {
        let server = ApprovalSocketServer(path: "/tmp/" + String(repeating: "a", count: 120))
        #expect(throws: (any Error).self) {
            try server.start(onRequest: { _, _ in }, onClose: { _ in })
        }
    }
}

private extension Data {
    /// Re-serialises to a single JSON line, as the hook client does before sending.
    func compactedJSONLine() throws -> Data {
        let object = try JSONSerialization.jsonObject(with: self)
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
