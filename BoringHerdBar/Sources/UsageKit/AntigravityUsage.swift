import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

/// One model's quota from a legacy source. `remainingFraction` is 0...1; a model with no quota info counts as depleted.
struct AntigravityModelConfig: Equatable, Sendable {
    var label: String
    var modelID: String?
    var remainingFraction: Double
    var resetTime: Date?
}

struct AntigravityKeychainToken: Equatable, Sendable {
    var accessToken: String?
    var expiry: Date?
}

/// Antigravity merged its quota pools on 2026-05-19: every Gemini model shares one pool ("Session" / "Weekly") and every
/// other model (Claude, GPT-OSS) shares a second ("Claude" / "Claude Weekly"), each with a 5-hour and a weekly window.
enum AntigravityUsageMapper {
    static let sessionLabel = "Session"
    static let weeklyLabel = "Weekly"
    static let claudeLabel = "Claude"
    static let claudeWeeklyLabel = "Claude Weekly"

    static let modelBlacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
    ]

    /// Matched by exact `bucketId` only, so a future bucket never silently joins a pool.
    static let summaryBuckets: [(id: String, label: String, period: TimeInterval)] = [
        ("gemini-5h", sessionLabel, UsagePeriod.session),
        ("gemini-weekly", weeklyLabel, UsagePeriod.week),
        ("3p-5h", claudeLabel, UsagePeriod.session),
        ("3p-weekly", claudeWeeklyLabel, UsagePeriod.week)
    ]

    /// `RetrieveUserQuotaSummary`, in either the LS envelope (`{"response": {"groups": ...}}`) or the bare remote shape.
    /// Nil means "not a summary" and the caller may fall back to the legacy endpoints. A non-nil result, even an empty
    /// one, is authoritative: the legacy path fabricates "fully used" from missing quota info. A bucket without a usable
    /// `remainingFraction` is dropped rather than shown as 0% or 100%.
    static func parseQuotaSummary(_ data: Data) -> [UsageWindow]? {
        guard let root = UsageParse.jsonObject(data),
              let groups = ((root["response"] as? [String: Any])?["groups"] ?? root["groups"]) as? [Any]
        else { return nil }
        var pooled: [String: (fraction: Double, reset: Date?)] = [:]
        for group in groups {
            for case let bucket as [String: Any] in (group as? [String: Any])?["buckets"] as? [Any] ?? [] {
                guard let id = bucket["bucketId"] as? String, summaryBuckets.contains(where: { $0.id == id }),
                      pooled[id] == nil, let fraction = UsageParse.number(bucket["remainingFraction"])
                else { continue }
                pooled[id] = (fraction, (bucket["resetTime"] as? String).flatMap(UsageParse.iso8601))
            }
        }
        return summaryBuckets.compactMap { spec in
            pooled[spec.id].map { window(spec.label, $0.fraction, $0.reset, spec.period) }
        }
    }

    /// LS `GetUserStatus`: plan name and model configs. Nil when the body has no `userStatus`.
    static func parseUserStatus(_ data: Data) -> (plan: String?, configs: [AntigravityModelConfig])? {
        guard let status = UsageParse.jsonObject(data)?["userStatus"] as? [String: Any] else { return nil }
        // Google's own `userTier` beats the Windsurf-inherited `planName`, which reads "Pro" for every paid tier.
        let tier = (status["userTier"] as? [String: Any])?["name"] as? String
        let legacyPlan = (((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"]) as? String
        let rows = ((status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [Any]) ?? []
        return (formatPlan(tier ?? legacyPlan), rows.compactMap(lsConfig))
    }

    static func parseCommandModelConfigs(_ data: Data) -> [AntigravityModelConfig]? {
        (UsageParse.jsonObject(data)?["clientModelConfigs"] as? [Any])?.compactMap(lsConfig)
    }

    private static func lsConfig(_ value: Any) -> AntigravityModelConfig? {
        guard let object = value as? [String: Any] else { return nil }
        return config(
            label: object["label"] as? String,
            modelID: (object["modelOrAlias"] as? [String: Any])?["model"] as? String,
            quota: object["quotaInfo"] as? [String: Any]
        )
    }

    /// Cloud Code `fetchAvailableModels`; drops `isInternal` and unlabeled models.
    static func parseCloudCodeModels(_ data: Data) -> [AntigravityModelConfig] {
        guard let models = UsageParse.jsonObject(data)?["models"] as? [String: Any] else { return [] }
        return models.compactMap { key, value -> AntigravityModelConfig? in
            guard let model = value as? [String: Any], model["isInternal"] as? Bool != true else { return nil }
            let label = (model["displayName"] as? String)?.nilIfEmpty ?? (model["label"] as? String)?.nilIfEmpty
            return config(label: label, modelID: (model["model"] as? String)?.nilIfEmpty ?? key, quota: model["quotaInfo"] as? [String: Any])
        }
    }

    /// Cloud Code `retrieveUserQuota`: buckets keyed by raw model id.
    static func parseQuotaBuckets(_ data: Data) -> [AntigravityModelConfig] {
        (UsageParse.jsonObject(data)?["buckets"] as? [Any] ?? []).compactMap { value in
            guard let bucket = value as? [String: Any], let id = (bucket["modelId"] as? String)?.nilIfEmpty else { return nil }
            return AntigravityModelConfig(
                label: id, modelID: id,
                remainingFraction: UsageParse.number(bucket["remainingFraction"]) ?? 0,
                resetTime: (bucket["resetTime"] as? String).flatMap(UsageParse.iso8601)
            )
        }
    }

    /// Cloud Code `loadCodeAssist` plan (paid tier preferred) and project.
    static func parseLoadCodeAssist(_ data: Data) -> (plan: String?, project: String?) {
        let object = UsageParse.jsonObject(data)
        let tier = ((object?["paidTier"] as? [String: Any])?["name"] as? String)
            ?? ((object?["currentTier"] as? [String: Any])?["name"] as? String)
        return (formatPlan(tier), (object?["cloudaicompanionProject"] as? String)?.nilIfEmpty)
    }

    /// Collapses model configs into the two 5-hour pool windows, keeping the worst fraction per pool; Gemini first.
    static func buildWindows(_ configs: [AntigravityModelConfig]) -> [UsageWindow] {
        var pooled: [String: (fraction: Double, reset: Date?)] = [:]
        for config in configs {
            let label = config.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !(config.modelID.map(modelBlacklist.contains) ?? false) else { continue }
            let pool = label.lowercased().contains("gemini") ? sessionLabel : claudeLabel
            if let existing = pooled[pool], existing.fraction <= config.remainingFraction { continue }
            pooled[pool] = (config.remainingFraction, config.resetTime)
        }
        return [sessionLabel, claudeLabel].compactMap { pool in
            pooled[pool].map { window(pool, $0.fraction, $0.reset, UsagePeriod.session) }
        }
    }

    static func window(_ label: String, _ fraction: Double, _ reset: Date?, _ period: TimeInterval) -> UsageWindow {
        // Whole percents, so an untouched window reads exactly 0.
        UsageWindow(label: label, usedPercent: ((1 - min(max(fraction, 0), 1)) * 100).rounded(), resetsAt: reset, periodSeconds: period)
    }

    /// "Google AI Pro" becomes "Pro"; "Gemini Code Assist in Google One AI Pro" yields the tier word.
    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if let range = trimmed.range(of: "Google AI "), range.lowerBound == trimmed.startIndex {
            return UsageParse.titleCased(String(trimmed[range.upperBound...]), separator: \.isWhitespace)
        }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(keyword.lowercased()) { return keyword }
        return UsageParse.titleCased(trimmed, separator: \.isWhitespace)
    }

    private static func config(label: String?, modelID: String?, quota: [String: Any]?) -> AntigravityModelConfig? {
        guard let label = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        return AntigravityModelConfig(
            label: label, modelID: modelID,
            remainingFraction: UsageParse.number(quota?["remainingFraction"]) ?? 0,
            resetTime: (quota?["resetTime"] as? String).flatMap(UsageParse.iso8601)
        )
    }
}

enum AntigravityAuth {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"

    /// The token from the Keychain item, which is a JSON object, a JSON string, a `Bearer` value or raw text, optionally
    /// go-keyring wrapped. Broken structured text is never sent as a bearer token.
    static func extractToken(_ raw: String) -> AntigravityKeychainToken? {
        let boundary = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        guard let unwrapped = UsageParse.unwrapGoKeyring(raw.trimmingCharacters(in: boundary)),
              let text = unwrapped.trimmingCharacters(in: boundary).nilIfEmpty
        else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
            if let object = json as? [String: Any] { return token(from: object) }
            return (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                .map { AntigravityKeychainToken(accessToken: $0, expiry: nil) }
        }
        if text.hasPrefix("{") || text.hasPrefix("[") { return nil }
        let bare = text.hasPrefix("Bearer ") ? String(text.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines) : text
        return bare.nilIfEmpty.map { AntigravityKeychainToken(accessToken: $0, expiry: nil) }
    }

    static func token(from object: [String: Any]) -> AntigravityKeychainToken? {
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let expiry = firstString(source, ["expiry", "expires_at", "expiresAt"]).flatMap(UsageParse.iso8601)
        if access == nil, firstString(source, ["refresh_token", "refreshToken"]) == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let found = token(from: nested) { return found }
            }
            return nil
        }
        return AntigravityKeychainToken(accessToken: access, expiry: expiry)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
    }
}

/// Probes the running language server first (richest, authoritative plan), then Cloud Code with the Keychain token.
/// The Keychain token is used as is: there is no Google OAuth refresh, so an expired one reads as stale.
struct AntigravityUsageSource: UsageSource {
    static let lsService = "exa.language_server_pb.LanguageServerService"
    static let cloudCodeURLs = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    static let lsMetadata = ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]
    /// Skew guard: a token about to expire counts as expired.
    static let expiryBuffer: TimeInterval = 60

    var context: UsageContext

    func load(now: Date) async throws -> UsageReading {
        let discovery = LanguageServerDiscovery(runner: context.runner)
        let probes: [LanguageServerDiscovery.Options] = [
            .init(processName: "language_server", markers: ["antigravity", "antigravity-ide"], csrfFlag: "--csrf_token", portFlag: "--extension_server_port"),
            .init(processName: "agy", markers: [], csrfFlag: "", portFlag: nil)
        ]
        for options in probes {
            if let server = await discovery.discover(options), let reading = await probeLanguageServer(server) { return reading }
        }
        return try await probeCloudCode(now: now)
    }

    // MARK: Language server

    private func probeLanguageServer(_ server: LanguageServerDiscovery.Result) async -> UsageReading? {
        // HTTPS first (self-signed cert), then HTTP, then the HTTP-only extension port.
        var endpoints = server.ports.flatMap { [("https", $0), ("http", $0)] }
        if let port = server.extensionPort { endpoints.append(("http", port)) }
        for (scheme, port) in endpoints {
            if let summary = await callLS(scheme, port, server.csrf, "RetrieveUserQuotaSummary"), (200..<300).contains(summary.statusCode),
               let windows = AntigravityUsageMapper.parseQuotaSummary(summary.body) {
                var plan: String?
                if let status = await callLS(scheme, port, server.csrf, "GetUserStatus"), (200..<300).contains(status.statusCode) {
                    plan = AntigravityUsageMapper.parseUserStatus(status.body)?.plan
                }
                return UsageReading(windows: windows, plan: plan, extra: nil)
            }
            guard let status = await callLS(scheme, port, server.csrf, "GetUserStatus"), (200..<300).contains(status.statusCode) else { continue }
            if let parsed = AntigravityUsageMapper.parseUserStatus(status.body) {
                let windows = AntigravityUsageMapper.buildWindows(parsed.configs)
                if !windows.isEmpty { return UsageReading(windows: windows, plan: parsed.plan, extra: nil) }
            }
            if let fallback = await callLS(scheme, port, server.csrf, "GetCommandModelConfigs"), (200..<300).contains(fallback.statusCode),
               let configs = AntigravityUsageMapper.parseCommandModelConfigs(fallback.body) {
                let windows = AntigravityUsageMapper.buildWindows(configs)
                if !windows.isEmpty { return UsageReading(windows: windows, plan: nil, extra: nil) }
            }
        }
        return nil
    }

    private func callLS(_ scheme: String, _ port: Int, _ csrf: String, _ method: String) async -> HTTPResponse? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.lsService)/\(method)") else { return nil }
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": Self.lsMetadata])
        let request = HTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1", "x-codeium-csrf-token": csrf],
            body: body, timeout: 10
        )
        return try? await context.loopbackHTTP.send(request)
    }

    // MARK: Cloud Code

    private enum CloudOutcome {
        case ok(Data)
        case authFailed
        case unavailable
    }

    private func probeCloudCode(now: Date) async throws -> UsageReading {
        let raw = await KeychainReader(runner: context.runner, denials: context.keychainDenials, reads: context.keychainReads).read(
            service: AntigravityAuth.keychainService, account: AntigravityAuth.keychainAccount
        )
        guard let raw, let keychain = AntigravityAuth.extractToken(raw), let token = keychain.accessToken else {
            throw UsageFailure.notSetUp("sign in to Antigravity")
        }
        if let expiry = keychain.expiry, expiry.timeIntervalSince(now) <= Self.expiryBuffer { throw UsageFailure.stale("open Antigravity") }
        switch await cloudUsage(token: token) {
        case .ok(let reading): return reading
        case .authFailed: throw UsageFailure.stale("open Antigravity")
        case .unavailable: throw UsageFailure.failed("Antigravity unavailable")
        }
    }

    private enum CloudResult {
        case ok(UsageReading)
        case authFailed
        case unavailable
    }

    private func cloudUsage(token: String) async -> CloudResult {
        // The summary is authoritative, so a parsed one never falls into the legacy chain below.
        switch await cloudCode("/v1internal:retrieveUserQuotaSummary", token, userAgent: "antigravity", body: [:]) {
        case .authFailed: return .authFailed
        case .ok(let data):
            if let windows = AntigravityUsageMapper.parseQuotaSummary(data) {
                return .ok(UsageReading(windows: windows, plan: await loadPlan(token), extra: nil))
            }
        case .unavailable: break
        }
        switch await cloudCode("/v1internal:fetchAvailableModels", token, userAgent: "antigravity", body: [:]) {
        case .authFailed: return .authFailed
        case .ok(let data):
            let windows = AntigravityUsageMapper.buildWindows(AntigravityUsageMapper.parseCloudCodeModels(data))
            if !windows.isEmpty { return .ok(UsageReading(windows: windows, plan: await loadPlan(token), extra: nil)) }
        case .unavailable: break
        }
        var plan: String?
        var project: String?
        switch await cloudCode("/v1internal:loadCodeAssist", token, userAgent: "agy", body: [:]) {
        case .authFailed: return .authFailed
        case .ok(let data): (plan, project) = AntigravityUsageMapper.parseLoadCodeAssist(data)
        case .unavailable: break
        }
        var quota = await cloudCode("/v1internal:retrieveUserQuota", token, userAgent: "agy", body: project.map { ["project": $0] } ?? [:])
        if case .unavailable = quota, project != nil {
            quota = await cloudCode("/v1internal:retrieveUserQuota", token, userAgent: "agy", body: [:])
        }
        switch quota {
        case .authFailed: return .authFailed
        case .ok(let data):
            let windows = AntigravityUsageMapper.buildWindows(AntigravityUsageMapper.parseQuotaBuckets(data))
            if !windows.isEmpty { return .ok(UsageReading(windows: windows, plan: plan, extra: nil)) }
        case .unavailable: break
        }
        return .unavailable
    }

    private func loadPlan(_ token: String) async -> String? {
        if case .ok(let data) = await cloudCode("/v1internal:loadCodeAssist", token, userAgent: "agy", body: [:]) {
            return AntigravityUsageMapper.parseLoadCodeAssist(data).plan
        }
        return nil
    }

    /// POSTs each Cloud Code base URL in turn. 401/403 short-circuits to `.authFailed` (the other base would reject the same token).
    private func cloudCode(_ path: String, _ token: String, userAgent: String, body: [String: String]) async -> CloudOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        for base in Self.cloudCodeURLs {
            guard let url = URL(string: base + path) else { continue }
            let request = HTTPRequest(
                method: "POST", url: url,
                headers: ["Accept": "application/json", "Content-Type": "application/json", "Authorization": "Bearer \(token)", "User-Agent": userAgent],
                body: payload, timeout: 15
            )
            guard let response = try? await context.http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
        }
        return .unavailable
    }
}
