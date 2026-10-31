import Foundation
import Testing

@testable import UsageKit

@Suite struct CodexUsageTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let usageBody = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {"used_percent": 21, "limit_window_seconds": 18000, "reset_at": 1800003600},
        "secondary_window": {"used_percent": 64.5, "limit_window_seconds": 604800, "reset_after_seconds": 86400}
      },
      "additional_rate_limits": [
        {"limit_name": "GPT-5.3-Codex-Spark", "rate_limit": {
          "primary_window": {"used_percent": 5, "limit_window_seconds": 18000},
          "secondary_window": {"used_percent": 9, "limit_window_seconds": 604800}}}
      ],
      "credits": {"has_credits": true, "balance": "821.9"}
    }
    """

    @Test func mapsSessionWeeklySparkAndCredits() throws {
        let reading = try #require(CodexUsageMapper.map(json(Self.usageBody), now: Self.now))
        #expect(reading.windows.map(\.label) == ["Session", "Weekly", "Spark", "Spark Weekly"])
        #expect(reading.windows.map(\.usedPercent) == [21, 64.5, 5, 9])
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(reading.windows[1].resetsAt == Self.now.addingTimeInterval(86400))
        #expect(reading.windows[2].resetsAt == nil)
        #expect(reading.plan == "Pro 100")
        #expect(reading.extra == .codexCredits(credits: 821, usd: 821 * 0.04))
    }

    @Test func classifiesByDurationWhenWeeklyMovesToPrimarySlot() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":604800}}}"#
        let reading = try #require(CodexUsageMapper.map(json(body), now: Self.now))
        #expect(reading.windows.map(\.label) == ["Weekly"])
        #expect(reading.windows[0].periodSeconds == 604_800)
    }

    @Test func fallsBackToSlotsWhenDurationIsUnfamiliar() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":999},"secondary_window":{"used_percent":2}}}"#
        let reading = try #require(CodexUsageMapper.map(json(body), now: Self.now))
        #expect(reading.windows.map(\.label) == ["Session", "Weekly"])
        #expect(reading.windows[0].periodSeconds == 999)
        #expect(reading.windows[1].periodSeconds == UsagePeriod.week)
    }

    @Test func usesHeaderPercentsAndExhaustedCreditsFlag() throws {
        let body = #"{"rate_limit":{"primary_window":{"limit_window_seconds":18000}},"credits":{"has_credits":false}}"#
        let reading = try #require(CodexUsageMapper.map(
            json(body, headers: ["X-Codex-Primary-Used-Percent": "33"]), now: Self.now
        ))
        #expect(reading.windows.map(\.usedPercent) == [33])
        #expect(reading.windows[0].resetsAt == nil)
        #expect(reading.extra == .codexCredits(credits: 0, usd: 0))
    }

    @Test func formatsPlanNames() {
        #expect(CodexUsageMapper.formatPlan("pro") == "Pro 200")
        #expect(CodexUsageMapper.formatPlan("plus") == "Plus")
        #expect(CodexUsageMapper.formatPlan("self_serve_business_prolite") == "Business Premium")
        #expect(CodexUsageMapper.formatPlan("") == nil)
    }

    // MARK: auth + source

    private func authJSON(exp: TimeInterval) -> String {
        #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"\#(fakeJWT(exp: exp))","refresh_token":"test-refresh","account_id":"acct-test"}}"#
    }

    private func source(_ http: FakeHTTPClient, home: URL, env: [String: String] = [:]) -> CodexUsageSource {
        CodexUsageSource(context: UsageContext(http: http, loopbackHTTP: http, runner: FakeRunner(), environment: env, home: home))
    }

    @Test func parsesAuthFileAndJwtExpiry() throws {
        let auth = try #require(CodexAuth.parse(authJSON(exp: 1_800_000_500)))
        #expect(auth.accountID == "acct-test")
        #expect(auth.accessTokenExpiry == Date(timeIntervalSince1970: 1_800_000_500))
        #expect(CodexAuth.parse(#"{"OPENAI_API_KEY":"sk-test"}"#)?.hasAPIKey == true)
    }

    @Test func sendsBearerAndAccountHeaders() async throws {
        let home = try makeHome(files: [".codex/auth.json": authJSON(exp: 1_800_000_500)])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(Self.usageBody) }
        let reading = try await source(http, home: home).load(now: Self.now)
        let request = try #require(http.requests.first)
        #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(request.headers["ChatGPT-Account-Id"] == "acct-test")
        #expect(reading.windows.count == 4)
    }

    @Test func expiredTokenIsStaleWithoutNetwork() async throws {
        let home = try makeHome(files: [".codex/auth.json": authJSON(exp: 1_799_999_000)])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient()
        await #expect(throws: UsageFailure.stale("open Codex")) { try await source(http, home: home).load(now: Self.now) }
        #expect(http.requests.isEmpty)
    }

    @Test func apiKeyOnlyAndMissingFileAreNotSetUp() async throws {
        let keyHome = try makeHome(files: [".codex/auth.json": #"{"OPENAI_API_KEY":"sk-test"}"#])
        let emptyHome = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: keyHome)
            try? FileManager.default.removeItem(at: emptyHome)
        }
        await #expect(throws: UsageFailure.notSetUp("usage is not available for an API key")) {
            try await source(FakeHTTPClient(), home: keyHome).load(now: Self.now)
        }
        await #expect(throws: UsageFailure.notSetUp("sign in to Codex")) {
            try await source(FakeHTTPClient(), home: emptyHome).load(now: Self.now)
        }
    }
}
