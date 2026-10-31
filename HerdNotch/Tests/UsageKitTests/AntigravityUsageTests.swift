import Foundation
import Testing

@testable import UsageKit

@Suite struct AntigravityUsageTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let summary = """
    {"response":{"groups":[
      {"buckets":[
        {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-10-14T15:00:00.123456789Z"},
        {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-10-20T00:00:00Z"},
        {"bucketId":"gemini-image-5h","remainingFraction":0.1}]},
      {"buckets":[
        {"bucketId":"3p-5h","remainingFraction":1},
        {"bucketId":"3p-weekly"},
        "garbage"]}]}}
    """

    @Test func summaryMapsExactPoolBucketsAndDropsUnusableOnes() throws {
        let windows = try #require(AntigravityUsageMapper.parseQuotaSummary(jsonData(Self.summary)))
        #expect(windows.map(\.label) == ["Session", "Weekly", "Claude"])
        #expect(windows.map(\.usedPercent) == [25, 50, 0])
        #expect(abs(try #require(windows[0].resetsAt).timeIntervalSince(epoch("2026-10-14T15:00:00Z"))) < 1)
        #expect(windows[0].periodSeconds == UsagePeriod.session)
        #expect(windows[1].periodSeconds == UsagePeriod.week)
        #expect(windows[2].resetsAt == nil)
    }

    @Test func summaryAcceptsBareRemoteEnvelopeAndEmptyIsAuthoritative() throws {
        #expect(AntigravityUsageMapper.parseQuotaSummary(jsonData(#"{"groups":[{"buckets":[{"bucketId":"3p-weekly","remainingFraction":0.2}]}]}"#))?
            .map(\.label) == ["Claude Weekly"])
        #expect(AntigravityUsageMapper.parseQuotaSummary(jsonData(#"{"groups":[]}"#))?.isEmpty == true)
        #expect(AntigravityUsageMapper.parseQuotaSummary(jsonData(#"{"nope":1}"#)) == nil)
        #expect(AntigravityUsageMapper.parseQuotaSummary(jsonData("<html>")) == nil)
    }

    @Test func legacyConfigsPoolToWorstFractionPerPool() throws {
        let status = """
        {"userStatus":{"userTier":{"name":"Google AI Pro"},"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 3 Pro (High)","modelOrAlias":{"model":"M1"},"quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-10-14T15:00:00Z"}},
          {"label":"Gemini 3 Flash","modelOrAlias":{"model":"M2"},"quotaInfo":{"remainingFraction":0.2}},
          {"label":"Claude Sonnet 4.5","modelOrAlias":{"model":"M3"},"quotaInfo":{"remainingFraction":0.9}},
          {"label":"Hidden","modelOrAlias":{"model":"MODEL_CHAT_20706"},"quotaInfo":{"remainingFraction":0}},
          {"label":"No quota info","modelOrAlias":{"model":"M4"}}]}}}
        """
        let parsed = try #require(AntigravityUsageMapper.parseUserStatus(jsonData(status)))
        #expect(parsed.plan == "Pro")
        let windows = AntigravityUsageMapper.buildWindows(parsed.configs)
        #expect(windows.map(\.label) == ["Session", "Claude"])
        // Worst fraction wins; a model with no quota info counts as depleted.
        #expect(windows.map(\.usedPercent) == [80, 100])
    }

    @Test func cloudCodeModelsAndBucketsParse() {
        let models = AntigravityUsageMapper.parseCloudCodeModels(jsonData("""
        {"models":{"a":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.5}},
                   "b":{"displayName":"Internal","isInternal":true,"quotaInfo":{"remainingFraction":0}}}}
        """))
        #expect(models.map(\.label) == ["Gemini 3 Pro"])
        let buckets = AntigravityUsageMapper.parseQuotaBuckets(jsonData(#"{"buckets":[{"modelId":"gemini-3-pro-preview","remainingFraction":0.4}]}"#))
        #expect(AntigravityUsageMapper.buildWindows(buckets).map(\.usedPercent) == [60])
        let load = AntigravityUsageMapper.parseLoadCodeAssist(jsonData(
            #"{"cloudaicompanionProject":"proj","currentTier":{"name":"Free"},"paidTier":{"name":"Gemini Code Assist in Google One AI Pro"}}"#
        ))
        #expect(load.plan == "Pro")
        #expect(load.project == "proj")
    }

    // MARK: keychain token

    @Test func extractsTokenFromEveryKeychainShape() {
        #expect(AntigravityAuth.extractToken(#"{"token":{"access_token":"a1","expiry":"2026-10-14T15:00:00Z"}}"#)
            == AntigravityKeychainToken(accessToken: "a1", expiry: epoch("2026-10-14T15:00:00Z")))
        #expect(AntigravityAuth.extractToken(#"{"oauth":{"accessToken":"a2"}}"#)?.accessToken == "a2")
        #expect(AntigravityAuth.extractToken("\"a3\"")?.accessToken == "a3")
        #expect(AntigravityAuth.extractToken("Bearer a4")?.accessToken == "a4")
        #expect(AntigravityAuth.extractToken("a5")?.accessToken == "a5")
        let wrapped = "go-keyring-base64:" + Data(#"{"access_token":"a6"}"#.utf8).base64EncodedString()
        #expect(AntigravityAuth.extractToken(wrapped)?.accessToken == "a6")
        #expect(AntigravityAuth.extractToken(#"{"broken":"#) == nil)
        #expect(AntigravityAuth.extractToken("") == nil)
    }

    // MARK: discovery

    @Test func discoveryRanksExactMarkerAboveSubstringAndParsesPorts() {
        let ps = """
          101 /Apps/Antigravity.app/bin/language_server_macos --ide_name antigravity-next --csrf_token zzz
          202 /Users/x/.antigravity/language_server --csrf_token tok-test --extension_server_port 5555 --app_data_dir antigravity
          303 /usr/bin/other --csrf_token nope
        """
        let options = LanguageServerDiscovery.Options(
            processName: "language_server", markers: ["antigravity"], csrfFlag: "--csrf_token", portFlag: "--extension_server_port"
        )
        let candidates = LanguageServerDiscovery.rankedCandidates(psOutput: ps, options: options)
        #expect(candidates.map(\.pid) == [202])
        #expect(LanguageServerDiscovery.extractFlag(command: candidates[0].command, flag: "--csrf_token") == "tok-test")
        #expect(LanguageServerDiscovery.parseListeningPorts("""
        language_ 202 u 8u IPv4 0x1 0t0 TCP 127.0.0.1:52168 (LISTEN)
        language_ 202 u 9u IPv4 0x2 0t0 TCP 127.0.0.1:52168 (LISTEN)
        language_ 202 u 10u IPv4 0x3 0t0 TCP *:4000 (LISTEN)
        """) == [4000, 52168])
    }

    // MARK: source

    @Test func languageServerSummaryBeatsEverythingAndKeychainIsNeverRead() async throws {
        let runner = FakeRunner { call in
            switch call.executable {
            case "/bin/ps":
                return ProcessResult(succeeded: true, stdout: "202 /x/language_server --csrf_token tok-test --app_data_dir antigravity --extension_server_port 5555\n")
            case "/usr/sbin/lsof", "/usr/bin/lsof":
                return ProcessResult(succeeded: true, stdout: "language_ 202 u 8u IPv4 0x1 0t0 TCP 127.0.0.1:52168 (LISTEN)\n")
            default:
                return ProcessResult(succeeded: false)
            }
        }
        let ls = FakeHTTPClient { request in
            if request.url.lastPathComponent == "RetrieveUserQuotaSummary" { return json(Self.summary) }
            return json(#"{"userStatus":{"userTier":{"name":"Google AI Ultra"}}}"#)
        }
        let remote = FakeHTTPClient()
        let source = AntigravityUsageSource(context: UsageContext(
            http: remote, loopbackHTTP: ls, runner: runner, environment: [:], home: URL(fileURLWithPath: "/nonexistent")
        ))
        let reading = try await source.load(now: Self.now)
        #expect(reading.windows.count == 3)
        #expect(reading.plan == "Ultra")
        #expect(ls.requests.first?.url.absoluteString.hasPrefix("https://127.0.0.1:52168/") == true)
        #expect(ls.requests.first?.headers["x-codeium-csrf-token"] == "tok-test")
        #expect(remote.requests.isEmpty)
        #expect(!runner.calls.contains { $0.executable == "/usr/bin/security" })
    }

    @Test func cloudCodeUsesKeychainTokenReadOnlyAndNeverRefreshes() async throws {
        let runner = FakeRunner { call in
            call.executable == "/usr/bin/security"
                ? ProcessResult(succeeded: true, stdout: #"{"token":{"access_token":"test-gemini","refresh_token":"test-refresh"}}"#)
                : ProcessResult(succeeded: false)
        }
        let http = FakeHTTPClient { request in
            request.url.path.hasSuffix("retrieveUserQuotaSummary") ? json(Self.summary) : json(#"{"paidTier":{"name":"Google AI Pro"}}"#)
        }
        let source = AntigravityUsageSource(context: UsageContext(
            http: http, loopbackHTTP: FakeHTTPClient(), runner: runner, environment: [:], home: URL(fileURLWithPath: "/nonexistent")
        ))
        let reading = try await source.load(now: Self.now)
        #expect(reading.windows.count == 3)
        #expect(runner.calls.contains(.init(
            executable: "/usr/bin/security", arguments: ["find-generic-password", "-a", "antigravity", "-s", "gemini", "-w"]
        )))
        #expect(http.requests.first?.headers["Authorization"] == "Bearer test-gemini")
        #expect(!http.requests.contains { $0.url.host == "oauth2.googleapis.com" })
    }

    @Test func expiredKeychainTokenIsStaleAndMissingIsNotSetUp() async throws {
        let expired = FakeRunner { call in
            call.executable == "/usr/bin/security"
                ? ProcessResult(succeeded: true, stdout: #"{"access_token":"t","expiry":"2020-01-01T00:00:00Z"}"#)
                : ProcessResult(succeeded: false)
        }
        let http = FakeHTTPClient()
        let home = URL(fileURLWithPath: "/nonexistent")
        await #expect(throws: UsageFailure.stale("open Antigravity")) {
            try await AntigravityUsageSource(context: UsageContext(
                http: http, loopbackHTTP: http, runner: expired, environment: [:], home: home
            )).load(now: Self.now)
        }
        await #expect(throws: UsageFailure.notSetUp("sign in to Antigravity")) {
            try await AntigravityUsageSource(context: UsageContext(
                http: http, loopbackHTTP: http, runner: FakeRunner(), environment: [:], home: home
            )).load(now: Self.now)
        }
        #expect(http.requests.isEmpty)
    }
}
