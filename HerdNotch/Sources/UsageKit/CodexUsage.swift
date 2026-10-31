import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

struct CodexAuth: Equatable, Sendable {
    var accessToken: String?
    var accountID: String?
    var hasAPIKey: Bool

    /// The access token's JWT `exp`, nil when it is not a decodable JWT.
    var accessTokenExpiry: Date? {
        accessToken.flatMap(UsageParse.jwtPayload)?["exp"].flatMap(UsageParse.number)
            .map { Date(timeIntervalSince1970: $0) }
    }

    static func parse(_ text: String) -> CodexAuth? {
        struct Document: Decodable {
            struct Tokens: Decodable {
                var accessToken: String?
                var accountID: String?
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case accountID = "account_id"
                }
            }
            var tokens: Tokens?
            var apiKey: String?
            enum CodingKeys: String, CodingKey {
                case tokens
                case apiKey = "OPENAI_API_KEY"
            }
        }
        guard let document = UsageParse.decodeWithHexFallback(text, decode: { try? JSONDecoder().decode(Document.self, from: $0) })
        else { return nil }
        return CodexAuth(
            accessToken: document.tokens?.accessToken?.nilIfEmpty,
            accountID: document.tokens?.accountID?.nilIfEmpty,
            hasAPIKey: document.apiKey?.isEmpty == false
        )
    }
}

enum CodexUsageMapper {
    private enum Kind { case session, weekly }

    private struct Candidate {
        var window: [String: Any]
        var usedPercent: Double?
        var fallback: Kind
    }

    static func map(_ response: HTTPResponse, now: Date) -> UsageReading? {
        guard let body = UsageParse.jsonObject(response.body) else { return nil }
        var windows = classified(
            body["rate_limit"] as? [String: Any], labels: ("Session", "Weekly"),
            headerPercents: (
                UsageParse.number(response.header("x-codex-primary-used-percent")),
                UsageParse.number(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        )
        windows += spark(body, now: now)
        return UsageReading(windows: windows, plan: formatPlan(body["plan_type"]), extra: credits(response, body))
    }

    /// Codex normally puts the 5-hour window in `primary_window` and the weekly one in `secondary_window`, but can
    /// move a sole weekly limit into the primary slot. Classify by `limit_window_seconds`; slots are only the fallback.
    private static func classified(
        _ rateLimit: [String: Any]?,
        labels: (session: String, weekly: String),
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date
    ) -> [UsageWindow] {
        let candidates = [
            candidate(rateLimit?["primary_window"], header: headerPercents.primary, fallback: .session),
            candidate(rateLimit?["secondary_window"], header: headerPercents.secondary, fallback: .weekly)
        ].compactMap { $0 }
        return [(Kind.session, labels.session), (Kind.weekly, labels.weekly)].compactMap { kind, label in
            let exact = candidates.first { exactKind($0.window) == kind }
            let slot = candidates.first { exactKind($0.window) == nil && $0.fallback == kind }
            guard let chosen = exact ?? slot, let used = chosen.usedPercent else { return nil }
            let period = periodSeconds(chosen.window) ?? (kind == .session ? UsagePeriod.session : UsagePeriod.week)
            return UsageWindow(
                label: label, usedPercent: UsageParse.clampPercent(used),
                resetsAt: resetDate(chosen.window, now: now), periodSeconds: period
            )
        }
    }

    private static func candidate(_ value: Any?, header: Double?, fallback: Kind) -> Candidate? {
        guard let window = value as? [String: Any] ?? (header == nil ? nil : [:]) else { return nil }
        return Candidate(window: window, usedPercent: UsageParse.number(window["used_percent"]) ?? header, fallback: fallback)
    }

    private static func exactKind(_ window: [String: Any]) -> Kind? {
        switch periodSeconds(window) {
        case UsagePeriod.session?: .session
        case UsagePeriod.week?: .weekly
        default: nil
        }
    }

    private static func periodSeconds(_ window: [String: Any]) -> TimeInterval? {
        UsageParse.number(window["limit_window_seconds"])
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = UsageParse.number(window["reset_at"]) { return Date(timeIntervalSince1970: resetAt) }
        return UsageParse.number(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
    }

    /// Model-specific limits (for example GPT-5.3-Codex-Spark) in `additional_rate_limits`, reusing the window shape.
    private static func spark(_ body: [String: Any], now: Date) -> [UsageWindow] {
        let entries = (body["additional_rate_limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let spark = entries.first(where: { entry in
            [entry["limit_name"], entry["metered_feature"]].compactMap { ($0 as? String)?.lowercased() }.contains { $0.contains("spark") }
        }), let rateLimit = spark["rate_limit"] as? [String: Any]
        else { return [] }
        return classified(rateLimit, labels: ("Spark", "Spark Weekly"), now: now)
    }

    /// Flex credits are worth 4 cents each. The count is floored before pricing, matching the Codex CLI.
    private static func credits(_ response: HTTPResponse, _ body: [String: Any]) -> UsageExtra? {
        var remaining: Double?
        if let credits = body["credits"] as? [String: Any] {
            remaining = UsageParse.number(credits["balance"]) ?? (credits["has_credits"] as? Bool == false ? 0 : nil)
        }
        guard let remaining = remaining ?? UsageParse.number(response.header("x-codex-credits-balance")) else { return nil }
        let count = max(0, Int(remaining.rounded(.down)))
        return .codexCredits(credits: count, usd: Double(count) * 0.04)
    }

    static func formatPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default: return UsageParse.titleCased(raw, separator: { $0 == "_" })
        }
    }
}

/// Never refreshes or writes a token: an expired login reads as stale until Codex renews it.
struct CodexUsageSource: UsageSource {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    var context: UsageContext

    func load(now: Date) async throws -> UsageReading {
        let home = context.env("CODEX_HOME").map(context.expandHome) ?? context.home.path + "/.codex"
        guard let text = readText(home + "/auth.json"), let auth = CodexAuth.parse(text) else {
            throw UsageFailure.notSetUp("sign in to Codex")
        }
        guard let token = auth.accessToken else {
            throw UsageFailure.notSetUp(auth.hasAPIKey ? "usage is not available for an API key" : "sign in to Codex")
        }
        if let expiry = auth.accessTokenExpiry, expiry <= now { throw UsageFailure.stale("open Codex") }

        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "UsageKit"]
        if let accountID = auth.accountID { headers["ChatGPT-Account-Id"] = accountID }
        let response: HTTPResponse
        do {
            response = try await context.http.send(HTTPRequest(url: Self.usageURL, headers: headers))
        } catch {
            throw UsageFailure.failed("connection failed")
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw UsageFailure.stale("open Codex") }
        guard (200..<300).contains(response.statusCode) else { throw commonFailure(response, now: now) }
        guard let reading = CodexUsageMapper.map(response, now: now) else { throw UsageFailure.failed("invalid response") }
        return reading
    }
}
