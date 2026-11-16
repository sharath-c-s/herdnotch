import Foundation
import Testing
import HerdKit

/// Loads `Fixtures/<name>` text files (pane captures) from the test bundle.
func paneFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.resourceURL).appending(path: "Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// A connector whose connection records what is written and replays fixed chunks, then EOF.
final class RecordingConnector: SocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: [Data]
    private let fail: Bool
    private var writes: [Data] = []

    init(reply: [Data] = [], fail: Bool = false) {
        self.reply = reply
        self.fail = fail
    }

    var written: [Data] { lock.withLock { writes } }

    func connect(path: String, timeout: TimeInterval) throws -> HerdrConnection {
        if fail { throw HerdrError.socketUnavailable("refused") }
        return Conn(owner: self)
    }

    private final class Conn: HerdrConnection, @unchecked Sendable {
        let owner: RecordingConnector
        var queue: [Data]
        init(owner: RecordingConnector) {
            self.owner = owner
            self.queue = owner.reply
        }
        func write(_ data: Data) throws { owner.lock.withLock { owner.writes.append(data) } }
        func read(timeout: TimeInterval) throws -> Data { queue.isEmpty ? Data() : queue.removeFirst() }
        func close() {}
    }
}
