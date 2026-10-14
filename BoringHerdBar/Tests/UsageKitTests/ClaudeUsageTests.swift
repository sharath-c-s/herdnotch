import Foundation
import Testing

@testable import UsageKit

@Suite struct ClaudeUsageTests {
    static let usageBody = """
    {
      "five_hour": {"utilization": 12.5, "resets_at": "2026-10-14T15:00:00.123456+00:00"},
      "seven_day": {"utilization": 40, "resets_at": 1792000000},
      "seven_day_sonnet": {"utilization": 7, "resets_at": 1792000000000},
      "seven_day_opus": null,
      "limits": [
        {"kind": "weekly_scoped", "percent": 55, "resets_at": "2026-10-20T00:00:00Z", "scope": {"model": {"display_name": "Fable"}}},
        {"kind": "weekly_scoped", "percent": 3, "scope": {"model": {"display_name": "Haiku"}}},
        {"kind": "session", "percent": 99, "scope": {"model": {"display_name": "Ignored"}}},
        {"kind": "weekly_scoped", "percent": 8, "scope": {"model": {"display_name": "Sonnet"}}}
      ],
      "extra_usage": {"is_enabled": true, "used_credits": 1250, "monthly_limit": 5000}
    }
    """

    @Test func mapsLegacyWindowsAndEveryScopedLimit() throws {
        let body = try #require(UsageParse.jsonObject(jsonData(Self.usageBody)))
        let mapped = ClaudeUsageMapper.map(body)
        #expect(mapped.windows.map(\.label) == ["Session", "Weekly", "Sonnet", "Fable", "Haiku"])
        #expect(mapped.windows.map(\.usedPercent) == [12.5, 40, 7, 55, 3])
        #expect(mapped.windows[0].periodSeconds == UsagePeriod.session)
        #expect(mapped.windows[3].periodSeconds == UsagePeriod.week)
    }

    @Test func resetsParseIsoEpochSecondsEpochMillisAndMissing() throws {
        let body = try #require(UsageParse.jsonObject(jsonData(Self.usageBody)))
        let windows = ClaudeUsageMapper.map(body).windows
        // The 6-digit fraction is kept to milliseconds.
        #expect(abs(try #require(windows[0].resetsAt).timeIntervalSince(epoch("2026-10-14T15:00:00Z"))) < 1)
        #expect(windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(windows[2].resetsAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(windows[4].resetsAt == nil)
    }

    @Test func extraUsageConvertsCentsToDollars() throws {
        let body = try #require(UsageParse.jsonObject(jsonData(Self.usageBody)))
        #expect(ClaudeUsageMapper.map(body).extra == .claudeExtraUsage(usedUSD: 12.5, limitUSD: 50))

        let uncapped = try #require(UsageParse.jsonObject(jsonData(#"{"extra_usage":{"is_enabled":true,"used_credits":300}}"#)))
        #expect(ClaudeUsageMapper.map(uncapped).extra == .claudeExtraUsage(usedUSD: 3, limitUSD: nil))

        let disabled = try #require(UsageParse.jsonObject(jsonData(#"{"extra_usage":{"is_enabled":false,"used_credits":300}}"#)))
        #expect(ClaudeUsageMapper.map(disabled).extra == nil)
    }

    @Test func planFormatsStoredAndLiveProfile() throws {
        #expect(ClaudeUsageMapper.formatPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeUsageMapper.formatPlan(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        let stored = ClaudeOAuth(accessToken: "t", subscriptionType: "pro")
        let profile = try #require(UsageParse.jsonObject(jsonData(
            #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#
        )))
        #expect(ClaudeUsageMapper.formatLivePlan(profile: profile, stored: stored) == "Max 20x")
    }

    // MARK: credentials

    static let keychainJSON = """
    {"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh","expiresAt":1800000100000,
     "scopes":["user:profile","user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"},
     "mcpOAuth":{"x":{"y":1}}}
    """

    @Test func parsesKeychainShapeAndExpiry() throws {
        let oauth = try #require(ClaudeCredentials.parse(Self.keychainJSON))
        #expect(oauth.accessToken == "test-access")
        #expect(oauth.canReadUsage)
        #expect(!oauth.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(oauth.isExpired(now: Date(timeIntervalSince1970: 1_800_000_100)))
    }

    @Test func parsesHexEncodedCredentialsAndRejectsTokenless() throws {
        let hex = Data(Self.keychainJSON.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(ClaudeCredentials.parse(hex)?.accessToken == "test-access")
        #expect(ClaudeCredentials.parse(#"{"claudeAiOauth":{"accessToken":"  "}}"#) == nil)
        #expect(ClaudeCredentials.parse("not json") == nil)
    }

    @Test func inferenceOnlyScopesCannotReadUsage() throws {
        let oauth = try #require(ClaudeCredentials.parse(#"{"claudeAiOauth":{"accessToken":"a","scopes":["user:inference"]}}"#))
        #expect(!oauth.canReadUsage)
    }

    @Test func configDirAddsHashedServiceBeforeDefault() {
        #expect(ClaudeCredentials.keychainServices(configDir: nil) == ["Claude Code-credentials"])
        let services = ClaudeCredentials.keychainServices(configDir: "/tmp/alt")
        #expect(services.count == 2)
        #expect(services[1] == "Claude Code-credentials")
        #expect(services[0].hasPrefix("Claude Code-credentials-"))
        #expect(services[0].count == "Claude Code-credentials-".count + 8)
    }

    // MARK: source

    private func source(
        runner: FakeRunner = FakeRunner(),
        http: FakeHTTPClient,
        home: URL,
        env: [String: String] = [:]
    ) -> ClaudeUsageSource {
        ClaudeUsageSource(context: UsageContext(http: http, loopbackHTTP: http, runner: runner, environment: env, home: home))
    }

    @Test func readsKeychainWithArgvAndSendsDocumentedHeaders() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = FakeRunner { _ in ProcessResult(succeeded: true, stdout: Self.keychainJSON + "\n") }
        let http = FakeHTTPClient { request in
            request.url.path.hasSuffix("profile")
                ? json(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#)
                : json(Self.usageBody)
        }
        let reading = try await source(runner: runner, http: http, home: home)
            .load(now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(runner.calls.first == .init(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        ))
        let usage = try #require(http.requests.first { $0.url.path == "/api/oauth/usage" })
        #expect(usage.method == "GET")
        #expect(usage.headers["Authorization"] == "Bearer test-access")
        #expect(usage.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(usage.headers["User-Agent"]?.hasPrefix("claude-cli/") == true)
        #expect(reading.plan == "Max 5x")
        #expect(reading.windows.count == 5)
    }

    @Test func profileIsFetchedOncePerToken() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = FakeRunner { _ in ProcessResult(succeeded: true, stdout: Self.keychainJSON) }
        let http = FakeHTTPClient { request in
            request.url.path.hasSuffix("profile") ? json(#"{"organization":{"organization_type":"claude_pro"}}"#) : json(Self.usageBody)
        }
        let source = source(runner: runner, http: http, home: home)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await source.load(now: now)
        _ = try await source.load(now: now)
        #expect(http.requests.filter { $0.url.path.hasSuffix("profile") }.count == 1)
        #expect(http.requests.filter { $0.url.path.hasSuffix("usage") }.count == 2)
    }

    @Test func expiredTokenIsStaleWithoutAnyNetworkCall() async throws {
        let home = try makeHome(files: [".claude/.credentials.json": Self.keychainJSON])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient()
        await #expect(throws: UsageFailure.stale("open Claude Code")) {
            try await source(http: http, home: home).load(now: Date(timeIntervalSince1970: 1_800_001_000))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func fallsBackToCredentialsFileAndHonorsConfigDir() async throws {
        let home = try makeHome(files: ["alt/.credentials.json": Self.keychainJSON])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(Self.usageBody) }
        let reading = try await source(http: http, home: home, env: ["CLAUDE_CONFIG_DIR": home.path + "/alt"])
            .load(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(reading.windows.first?.label == "Session")
    }

    @Test func missingCredentialsIsNotSetUp() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: UsageFailure.notSetUp("sign in to Claude Code")) {
            try await source(http: FakeHTTPClient(), home: home).load(now: Date())
        }
    }

    @Test func unauthorizedIsStaleAndNeverRefreshes() async throws {
        let home = try makeHome(files: [".claude/.credentials.json": Self.keychainJSON])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(401, "{}") }
        await #expect(throws: UsageFailure.stale("open Claude Code")) {
            try await source(http: http, home: home).load(now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(http.requests.allSatisfy { $0.method == "GET" && $0.url.host == "api.anthropic.com" })
        #expect(!http.requests.contains { $0.url.path.contains("token") })
    }
}
