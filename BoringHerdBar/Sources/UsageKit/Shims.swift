import Foundation
import HerdKit
import os

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval

    init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 10) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// `allowsInsecureLoopback` trusts a self-signed certificate for 127.0.0.1 only, which is what
    /// Antigravity's local language server serves.
    init(allowsInsecureLoopback: Bool = false) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        session = URLSession(
            configuration: configuration,
            delegate: allowsInsecureLoopback ? LoopbackTrustDelegate() : nil,
            delegateQueue: nil
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

struct ProcessResult: Sendable {
    var succeeded: Bool
    var status: Int32
    var stdout: String
    var stderr: String

    init(succeeded: Bool, stdout: String = "", stderr: String = "", status: Int32? = nil) {
        self.succeeded = succeeded
        self.status = status ?? (succeeded ? 0 : 1)
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an executable with an argv array (never a shell string). A timeout kills the process and
/// reports `succeeded == false`.
protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunner {
    init() {}

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let output = try BlockingProcess.run(executable, arguments, timeout: timeout)
                    return ProcessResult(
                        succeeded: output.succeeded, stdout: output.stdout, stderr: output.stderr, status: output.status)
                })
            }
        }
    }
}

/// Static messages only: callers must never interpolate tokens, ids or response bodies.
enum UsageLog {
    private static let logger = Logger(subsystem: "UsageKit", category: "usage")

    static func warn(_ message: StaticString) {
        logger.warning("\(message, privacy: .public)")
    }
}
