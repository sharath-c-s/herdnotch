import Foundation
import Testing

@testable import UsageKit

@Suite struct UsageFetcherTests {
    static let credentials = #"{"claudeAiOauth":{"accessToken":"test-access","expiresAt":9999999999999,"subscriptionType":"pro"}}"#
    static let usage = #"{"five_hour":{"utilization":10,"resets_at":"2026-10-14T15:00:00Z"}}"#

    private struct Harness {
        var fetcher: UsageFetcher
        var http: FakeHTTPClient
        var clock: Clock
        var home: URL
        var usageCalls: Int { http.requests.filter { $0.url.path == "/api/oauth/usage" }.count }
    }

    private func harness(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) throws -> Harness {
        let home = try makeHome(files: [".claude/.credentials.json": Self.credentials])
        let http = FakeHTTPClient(handler)
        let clock = Clock()
        let fetcher = UsageFetcher(http: http, loopbackHTTP: http, runner: FakeRunner(), environment: [:], home: home, now: { clock.now })
        return Harness(fetcher: fetcher, http: http, clock: clock, home: home)
    }

    private static func ok(_ request: HTTPRequest) -> HTTPResponse {
        request.url.path.hasSuffix("profile") ? json(404, "{}") : json(usage)
    }

    @Test func successStoresLastGood() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let snapshot = await h.fetcher.fetch(.claude)
        #expect(snapshot.state == .ok)
        #expect(snapshot.windows.map(\.usedPercent) == [10])
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.updatedAt == h.clock.now)
    }

    @Test func rateLimitHonorsRetryAfterSecondsKeepsLastGoodAndSkipsNetworkDuringCooldown() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let good = await h.fetcher.fetch(.claude)

        h.clock.advance(60)
        h.http.respond { _ in json(429, "{}", headers: ["Retry-After": "120"]) }
        let limited = await h.fetcher.fetch(.claude)
        #expect(limited.state == .rateLimited(until: h.clock.now.addingTimeInterval(120)))
        #expect(limited.windows == good.windows)
        #expect(limited.updatedAt == good.updatedAt)

        let callsBefore = h.usageCalls
        h.clock.advance(119)
        let cooling = await h.fetcher.fetch(.claude)
        #expect(cooling.state == .rateLimited(until: limited.state.until))
        #expect(cooling.windows == good.windows)
        #expect(h.usageCalls == callsBefore)

        h.clock.advance(2)
        h.http.respond(Self.ok)
        let recovered = await h.fetcher.fetch(.claude)
        #expect(recovered.state == .ok)
        #expect(h.usageCalls == callsBefore + 1)
    }

    @Test func rateLimitWithoutRetryAfterCoolsDownFiveMinutes() async throws {
        let h = try harness { _ in json(429, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let first = await h.fetcher.fetch(.claude)
        #expect(first.state == .rateLimited(until: h.clock.now.addingTimeInterval(300)))
        #expect(first.windows.isEmpty)
    }

    @Test func rateLimitParsesHttpDateRetryAfter() async throws {
        let h = try harness { _ in
            json(429, "{}", headers: ["Retry-After": "Sat, 15 Jan 2027 08:03:20 GMT"])
        }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let now = try #require(UsageParse.httpDate("Sat, 15 Jan 2027 08:00:00 GMT"))
        let clock = Clock(now)
        let fetcher = UsageFetcher(http: h.http, loopbackHTTP: h.http, runner: FakeRunner(), environment: [:], home: h.home, now: { clock.now })
        let snapshot = await fetcher.fetch(.claude)
        #expect(snapshot.state == .rateLimited(until: now.addingTimeInterval(200)))
    }

    @Test func networkAndServerErrorsKeepLastGood() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let good = await h.fetcher.fetch(.claude)

        h.http.respond { _ in json(500, "oops") }
        let server = await h.fetcher.fetch(.claude)
        #expect(server.state == .error("HTTP 500"))
        #expect(server.windows == good.windows)

        h.http.respond { _ in throw URLError(.notConnectedToInternet) }
        let network = await h.fetcher.fetch(.claude)
        #expect(network.state == .error("connection failed"))
        #expect(network.windows == good.windows)

        h.http.respond { _ in json(200, "<html>") }
        #expect(await h.fetcher.fetch(.claude).state == .error("invalid response"))
    }

    @Test func authFailureIsStaleSinceLastGood() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let good = await h.fetcher.fetch(.claude)
        h.clock.advance(300)
        h.http.respond { _ in json(401, "{}") }
        let stale = await h.fetcher.fetch(.claude)
        #expect(stale.state == .stale(since: good.updatedAt, reason: "open Claude Code"))
        #expect(stale.windows == good.windows)
    }

    @Test func notSetUpDropsLastGood() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = await h.fetcher.fetch(.claude)
        try FileManager.default.removeItem(at: h.home.appendingPathComponent(".claude/.credentials.json"))
        let snapshot = await h.fetcher.fetch(.claude)
        #expect(snapshot.state == .notSetUp(reason: "sign in to Claude Code"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test func cooldownIsPerProvider() async throws {
        let h = try harness { _ in json(429, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = await h.fetcher.fetch(.claude)
        // Codex has no auth file here, so it reports its own state instead of inheriting Claude's cooldown.
        let codex = await h.fetcher.fetch(.codex)
        #expect(codex.state == .notSetUp(reason: "sign in to Codex"))
    }

    @Test func concurrentFetchesShareOneRequest() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        async let a = h.fetcher.fetch(.claude)
        async let b = h.fetcher.fetch(.claude)
        let (first, second) = await (a, b)
        #expect(first == second)
        #expect(h.usageCalls == 1)
    }
}

private extension UsageState {
    var until: Date {
        if case .rateLimited(let until) = self { return until }
        return .distantPast
    }
}
