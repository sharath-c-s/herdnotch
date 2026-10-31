import Foundation

@testable import UsageKit

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private var handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse = { _ in HTTPResponse(statusCode: 404) }) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }

    func respond(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        lock.withLock { self.handler = handler }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let current = lock.withLock { () -> @Sendable (HTTPRequest) throws -> HTTPResponse in
            recorded.append(request)
            return handler
        }
        return try current(request)
    }
}

/// Answers by executable and a substring of the joined arguments; unmatched calls fail like a missing item.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (Call) -> ProcessResult

    init(_ handler: @escaping @Sendable (Call) -> ProcessResult = { _ in ProcessResult(succeeded: false) }) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments)
        lock.withLock { recorded.append(call) }
        return handler(call)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
}

func json(_ body: String, headers: [String: String] = [:]) -> HTTPResponse {
    json(200, body, headers: headers)
}

func jsonData(_ body: String) -> Data { Data(body.utf8) }

/// A throwaway home directory, removed when the value is released by the test's `defer`.
func makeHome(files: [String: String] = [:]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagekit-\(UUID().uuidString)")
    for (path, text) in files {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// An unsigned JWT-shaped string whose payload carries `exp` (epoch seconds). Not a real token.
func fakeJWT(exp: TimeInterval) -> String {
    func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    return "\(b64(#"{"alg":"none"}"#)).\(b64(#"{"exp":\#(Int(exp))}"#)).sig"
}

func epoch(_ iso: String) -> Date { UsageParse.iso8601(iso)! }
