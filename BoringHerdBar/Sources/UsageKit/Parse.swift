import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

enum UsageParse {
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Accepts JSON numbers and numeric strings; rejects booleans and non-finite values.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let string = value as? String {
            let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return parsed?.isFinite == true ? parsed : nil
        }
        return nil
    }

    static func clampPercent(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 100) : 0
    }

    /// ISO-8601 string, or epoch seconds or milliseconds (told apart by magnitude). Anything else is nil.
    static func date(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let date = iso8601(text) {
            return date
        }
        guard let number = number(value) else { return nil }
        let milliseconds = abs(number) < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO = Date.ISO8601FormatStyle()

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }()

    static func iso8601(_ text: String) -> Date? {
        // Servers send variable fractional digits (up to nanoseconds); the formatter is reliable at exactly 3 or none.
        let truncated = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        if let date = try? Date(truncated, strategy: fractionalISO) { return date }
        return try? Date(text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression), strategy: plainISO)
    }

    /// `Retry-After` as delta-seconds (`0` stays 0) or an HTTP-date rounded up to whole seconds.
    static func retryAfter(_ response: HTTPResponse, now: Date) -> TimeInterval? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if let seconds = Int(raw), seconds >= 0 { return TimeInterval(seconds) }
        return httpDate(raw).map { max(0, $0.timeIntervalSince(now).rounded(.up)) }
    }

    static func httpDate(_ value: String) -> Date? {
        httpDateFormatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Decodes JSON text, falling back to a hex-encoded JSON blob (some tools store credentials as hex).
    static func decodeWithHexFallback<T>(_ text: String, decode: (Data) -> T?) -> T? {
        if let decoded = decode(Data(text.utf8)) { return decoded }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return decode(Data(decoded.utf8))
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Unwraps a `go-keyring-base64:` value (how Go tools store secrets in the Keychain); other text passes through trimmed.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    static func titleCased(_ text: String, separator isSeparator: (Character) -> Bool, lowercasingTail: Bool = false) -> String {
        text.split(whereSeparator: isSeparator)
            .map { word in
                word.prefix(1).uppercased() + (lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst()))
            }
            .joined(separator: " ")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Reads a file's text, nil when it is absent or unreadable. Read-only by construction.
func readText(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// Maps a non-2xx response to the failure every source shares. 401/403 are handled by each source.
func commonFailure(_ response: HTTPResponse, now: Date) -> UsageFailure {
    if response.statusCode == 429 {
        return .rateLimited(retryAfter: UsageParse.retryAfter(response, now: now))
    }
    return .failed("HTTP \(response.statusCode)")
}

/// The environment and filesystem roots sources read, injected so tests never touch the real home.
struct UsageContext: Sendable {
    var http: any HTTPClient
    var loopbackHTTP: any HTTPClient
    var runner: any ProcessRunner
    var environment: [String: String]
    var home: URL
    var keychainDenials = KeychainDenials()
    var keychainReads = KeychainReads()

    func env(_ name: String) -> String? {
        environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func expandHome(_ path: String) -> String {
        path.hasPrefix("~") ? home.path + path.dropFirst() : path
    }
}
