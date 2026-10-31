import CryptoKit
import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

struct ClaudeOAuth: Equatable, Sendable {
    var accessToken: String
    /// Epoch milliseconds.
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?

    func isExpired(now: Date) -> Bool {
        expiresAt.map { $0 <= now.timeIntervalSince1970 * 1000 } ?? false
    }

    /// Claude Code's usage endpoint needs `user:profile`; an inference-only token (`claude setup-token`) lacks it.
    var canReadUsage: Bool { scopes?.contains("user:profile") ?? true }
}

enum ClaudeCredentials {
    static let servicePrefix = "Claude Code-credentials"

    private struct Document: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Double?
            var subscriptionType: String?
            var rateLimitTier: String?
            var scopes: [String]?
        }
        var claudeAiOauth: OAuth?
    }

    /// Parses the keychain or `.credentials.json` document; nil when it has no non-blank access token.
    static func parse(_ text: String) -> ClaudeOAuth? {
        guard let oauth = UsageParse.decodeWithHexFallback(text, decode: { try? JSONDecoder().decode(Document.self, from: $0) })?
            .claudeAiOauth,
            let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return nil }
        return ClaudeOAuth(
            accessToken: token,
            expiresAt: oauth.expiresAt,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier,
            scopes: oauth.scopes
        )
    }

    /// Keychain services in probe order: the `CLAUDE_CONFIG_DIR`-hashed one (when set), then the default.
    static func keychainServices(configDir: String?) -> [String] {
        guard let configDir else { return [servicePrefix] }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return ["\(servicePrefix)-\(suffix)", servicePrefix]
    }
}

enum ClaudeUsageMapper {
    static func map(_ body: [String: Any]) -> (windows: [UsageWindow], extra: UsageExtra?) {
        var windows: [UsageWindow] = []
        func add(_ label: String, used: Double?, resets: Any?, period: TimeInterval) {
            guard let used, !windows.contains(where: { $0.label == label }) else { return }
            windows.append(UsageWindow(
                label: label, usedPercent: UsageParse.clampPercent(used),
                resetsAt: UsageParse.date(resets), periodSeconds: period
            ))
        }
        func legacy(_ key: String, _ label: String, _ period: TimeInterval) {
            guard let object = body[key] as? [String: Any] else { return }
            add(label, used: UsageParse.number(object["utilization"]), resets: object["resets_at"], period: period)
        }
        legacy("five_hour", "Session", UsagePeriod.session)
        legacy("seven_day", "Weekly", UsagePeriod.week)
        legacy("seven_day_sonnet", "Sonnet", UsagePeriod.week)
        // Per-model weekly windows moved from `seven_day_<model>` keys into `limits[]`.
        for entry in body["limits"] as? [Any] ?? [] {
            guard let object = entry as? [String: Any], object["kind"] as? String == "weekly_scoped",
                  let model = (object["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            add(name, used: UsageParse.number(object["percent"]), resets: object["resets_at"], period: UsagePeriod.week)
        }
        return (windows, extra(body["extra_usage"]))
    }

    private static func extra(_ value: Any?) -> UsageExtra? {
        guard let object = value as? [String: Any], object["is_enabled"] as? Bool == true,
              let usedCents = UsageParse.number(object["used_credits"])
        else { return nil }
        let used = usedCents.rounded() / 100
        if let limitCents = UsageParse.number(object["monthly_limit"]), limitCents > 0 {
            return .claudeExtraUsage(usedUSD: used, limitUSD: limitCents.rounded() / 100)
        }
        return used > 0 ? .claudeExtraUsage(usedUSD: used, limitUSD: nil) : nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let base = UsageParse.titleCased(raw, separator: { $0 == " " }, lowercasingTail: true)
        guard let tier = rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[match])"
    }

    /// `organization_type` arrives as `claude_max` / `claude_pro`; the stored login fills any field the profile omits.
    static func formatLivePlan(profile: [String: Any], stored: ClaudeOAuth) -> String? {
        guard let organization = profile["organization"] as? [String: Any] else { return nil }
        var type = organization["organization_type"] as? String
        if let current = type, current.hasPrefix("claude_") { type = String(current.dropFirst("claude_".count)) }
        return formatPlan(
            subscriptionType: type ?? stored.subscriptionType,
            rateLimitTier: organization["rate_limit_tier"] as? String ?? stored.rateLimitTier
        )
    }
}

/// Never refreshes or writes a token: an expired login reads as stale until Claude Code renews it.
actor ClaudeUsageSource: UsageSource {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let userAgent = "claude-cli/2.1.294 (external, cli)"

    private let context: UsageContext
    private var cachedPlan: (token: String, plan: String?)?

    init(context: UsageContext) {
        self.context = context
    }

    func load(now: Date) async throws -> UsageReading {
        let candidates = await credentialCandidates()
        guard !candidates.isEmpty else { throw UsageFailure.notSetUp("sign in to Claude Code") }
        guard let oauth = candidates.first(where: { !$0.isExpired(now: now) }) else {
            throw UsageFailure.stale("open Claude Code")
        }
        guard oauth.canReadUsage else { throw UsageFailure.notSetUp("sign in to Claude Code again for usage") }

        let response = try await get(Self.usageURL, token: oauth.accessToken, withContentType: true)
        if response.statusCode == 401 || response.statusCode == 403 { throw UsageFailure.stale("open Claude Code") }
        guard (200..<300).contains(response.statusCode) else { throw commonFailure(response, now: now) }
        guard let body = UsageParse.jsonObject(response.body) else { throw UsageFailure.failed("invalid response") }

        let mapped = ClaudeUsageMapper.map(body)
        return UsageReading(windows: mapped.windows, plan: await plan(for: oauth), extra: mapped.extra)
    }

    private func credentialCandidates() async -> [ClaudeOAuth] {
        let keychain = KeychainReader(runner: context.runner, denials: context.keychainDenials, reads: context.keychainReads)
        let configDir = context.env("CLAUDE_CONFIG_DIR")
        var found: [ClaudeOAuth] = []
        for service in ClaudeCredentials.keychainServices(configDir: configDir) {
            if let text = await keychain.read(service: service), let oauth = ClaudeCredentials.parse(text) {
                found.append(oauth)
            }
        }
        let home = configDir.map(context.expandHome) ?? context.home.path + "/.claude"
        if let text = readText(home + "/.credentials.json"), let oauth = ClaudeCredentials.parse(text) {
            found.append(oauth)
        }
        return found
    }

    /// The live plan from `/api/oauth/profile`, fetched once per token. A failed profile call falls back to the
    /// stored login's plan and is retried next poll (ponytail: cache the failure too if the endpoint gets throttled).
    private func plan(for oauth: ClaudeOAuth) async -> String? {
        if let cachedPlan, cachedPlan.token == oauth.accessToken { return cachedPlan.plan }
        let stored = ClaudeUsageMapper.formatPlan(subscriptionType: oauth.subscriptionType, rateLimitTier: oauth.rateLimitTier)
        guard let response = try? await get(Self.profileURL, token: oauth.accessToken, withContentType: false),
              (200..<300).contains(response.statusCode),
              let profile = UsageParse.jsonObject(response.body),
              let live = ClaudeUsageMapper.formatLivePlan(profile: profile, stored: oauth)
        else { return stored }
        cachedPlan = (oauth.accessToken, live)
        return live
    }

    private func get(_ url: URL, token: String, withContentType: Bool) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]
        if withContentType {
            headers["Content-Type"] = "application/json"
            headers["User-Agent"] = Self.userAgent
        }
        do {
            return try await context.http.send(HTTPRequest(url: url, headers: headers))
        } catch {
            throw UsageFailure.failed("connection failed")
        }
    }
}
