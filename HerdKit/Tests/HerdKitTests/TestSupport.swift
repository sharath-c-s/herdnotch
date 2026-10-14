import Foundation
import HerdKit

// MARK: - Fixtures

/// Loads the real herdr payloads captured from this machine.
///
/// Fixtures are stored pretty-printed for reviewability, but the wire format is one JSON document per
/// line, so ``wireLine(_:)`` re-serialises them compactly before they are fed to the framer. Using the
/// captured bytes rather than hand-written JSON is the point: it catches field-name drift that an
/// invented fixture would happily agree with.
enum Fixture {
    /// A fixture could not be located in the test bundle.
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name).json is not in the test bundle" }
    }

    /// Raw bytes of `Fixtures/<name>.json`.
    ///
    /// - Parameter name: Fixture basename without extension.
    /// - Returns: The file's contents.
    /// - Throws: ``Missing`` if the resource is absent, or a read error.
    static func data(_ name: String) throws -> Data {
        guard let root = Bundle.module.resourceURL else { throw Missing(name: name) }
        let url = root.appending(path: "Fixtures/\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(name: name) }
        return try Data(contentsOf: url)
    }

    /// The fixture as a single newline-terminated wire line.
    ///
    /// - Parameter name: Fixture basename without extension.
    /// - Returns: Compact JSON plus a trailing `\n`, exactly what herdr writes to the socket.
    /// - Throws: ``Missing`` if the fixture is absent, or a serialisation error if it is not valid JSON.
    static func wireLine(_ name: String) throws -> Data {
        var line = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data(name)))
        line.append(UInt8(ascii: "\n"))
        return line
    }
}

// MARK: - Mutable state across a dispatch boundary

/// A lock-guarded box used to carry a value out of a `@Sendable` closure.
///
/// Needed because a test that must not hang has to run the risky call on another queue, and a plain
/// captured `var` cannot be mutated from concurrently executing code.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    /// The boxed value. Reads and writes are serialised by an internal lock.
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

// MARK: - Fake transport

/// Thread-safe connect counter, so a route can behave differently on its second connect.
private final class ConnectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new count.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// A ``SocketConnecting`` that replays scripted bytes per socket path.
///
/// Every failure the panel has to survive is reachable from here without starting, stopping or
/// wedging a real herdr server: an unreachable socket, a server that answers one method and not
/// another, a server that dies between the liveness probe and the data call.
struct FakeConnector: SocketConnecting {
    /// How one socket path behaves.
    enum Route: Sendable {
        /// `connect()` always fails, as it does for a stale socket file left by a stopped session.
        case unreachable
        /// `connect()` succeeds; each request is answered from this method-name to chunks table.
        /// A method with no entry gets an immediate EOF, which is what a crashing server looks like.
        case serving([String: [Data]])
        /// `connect()` succeeds exactly once, then fails: a session that stops between the liveness
        /// probe and the data calls.
        case reachableOnce
        /// `connect()` succeeds immediately and every read then runs its timeout out.
        ///
        /// This is what the local end of a broken `ssh -L` forward looks like, and it is the only failure
        /// mode that costs real time: `ssh` accepts the connection on this machine before it discovers the
        /// far side is unreachable, so the socket is reachable and simply never answers. A refused connect,
        /// which is what a stale local socket gives, costs nothing.
        case stalling
        /// `connect()` succeeds; the first request naming `method` gets an immediate EOF and every later one
        /// is answered from `table`.
        ///
        /// A one-shot socket fault on a server that is otherwise fine, which is the shape of the failure that
        /// used to erase a whole session's rows: the peer closes the connection between the liveness probe
        /// and the request, and since every call opens a fresh connection, simply asking again works.
        ///
        /// Keyed on the method rather than on a connect count so the test does not have to know how many
        /// connects discovery's liveness probe spends first.
        case faultingFirstRequest(method: String, table: [String: [Data]])
    }

    private let routes: [String: Route]
    private let counters: [String: ConnectCounter]

    /// Creates a connector.
    ///
    /// - Parameter routes: Socket path to behaviour. Any path not listed is unreachable.
    init(routes: [String: Route]) {
        self.routes = routes
        self.counters = routes.keys.reduce(into: [:]) { $0[$1] = ConnectCounter() }
    }

    func connect(path: String, timeout: TimeInterval) throws -> HerdrConnection {
        switch routes[path] {
        case .serving(let table):
            return ScriptedConnection(table: table)
        case .reachableOnce:
            guard counters[path]?.next() == 1 else {
                throw HerdrError.socketUnavailable("fake session at \(path) stopped")
            }
            return ScriptedConnection(table: [:])
        case .stalling:
            return StallingConnection()
        case .faultingFirstRequest(let method, let table):
            return ScriptedConnection(
                table: table,
                faulting: method,
                attempts: counters[path] ?? ConnectCounter()
            )
        case .unreachable, .none:
            throw HerdrError.socketUnavailable("no fake server at \(path)")
        }
    }
}

/// A connector that spends real time in `connect`, then hands back a connection that always runs its
/// read timeout out.
///
/// Used to prove the call timeout is one end-to-end budget: the only way to distinguish a shared
/// deadline from a per-phase one is to measure a call whose phases both consume time.
struct SlowConnector: SocketConnecting {
    /// Seconds to burn inside `connect`, capped by whatever budget it is given.
    let connectDelay: TimeInterval

    func connect(path: String, timeout: TimeInterval) throws -> HerdrConnection {
        Thread.sleep(forTimeInterval: min(connectDelay, max(0, timeout)))
        return StallingConnection()
    }
}

/// A connection that waits out whatever read timeout it is handed and then reports a timeout, which
/// is exactly what a real socket carrying `SO_RCVTIMEO` does when the peer stays silent.
final class StallingConnection: HerdrConnection, @unchecked Sendable {
    func write(_ data: Data) throws {}

    func read(timeout: TimeInterval) throws -> Data {
        Thread.sleep(forTimeInterval: max(0, timeout))
        throw HerdrError.timeout
    }

    func close() {}
}

/// A connection that answers whatever method the request names.
///
/// Reads hand back one queued chunk at a time so a test can split a response across `recv()`
/// boundaries. An exhausted queue returns empty `Data`, which is EOF.
private final class ScriptedConnection: HerdrConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let table: [String: [Data]]

    /// Method whose first request is answered with an immediate EOF, or `nil` to answer every request.
    private let faulting: String?

    /// Counts requests for ``faulting`` across every connection this route hands out, so "the first one"
    /// means the first one the whole route sees rather than the first on each connection.
    private let attempts: ConnectCounter?

    private var queued: [Data] = []

    init(table: [String: [Data]], faulting: String? = nil, attempts: ConnectCounter? = nil) {
        self.table = table
        self.faulting = faulting
        self.attempts = attempts
    }

    func write(_ data: Data) throws {
        let request = try? JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        let method = request?["method"] as? String ?? ""
        if method == faulting, attempts?.next() == 1 {
            lock.withLock { queued = [] }
            return
        }
        lock.withLock { queued = table[method] ?? [] }
    }

    func read(timeout: TimeInterval) throws -> Data {
        lock.withLock { queued.isEmpty ? Data() : queued.removeFirst() }
    }

    func close() {}
}
