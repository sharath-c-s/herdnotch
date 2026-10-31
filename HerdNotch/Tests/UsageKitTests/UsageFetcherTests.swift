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
        h.http.respond { _ in json(429, "{}", headers: ["Retry-After": "900"]) }
        let limited = await h.fetcher.fetch(.claude)
        #expect(limited.state == .rateLimited(until: h.clock.now.addingTimeInterval(900)))
        #expect(limited.windows == good.windows)
        #expect(limited.updatedAt == good.updatedAt)

        let callsBefore = h.usageCalls
        h.clock.advance(899)
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
            json(429, "{}", headers: ["Retry-After": "Sat, 15 Jan 2027 08:10:00 GMT"])
        }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let now = try #require(UsageParse.httpDate("Sat, 15 Jan 2027 08:00:00 GMT"))
        let clock = Clock(now)
        let fetcher = UsageFetcher(http: h.http, loopbackHTTP: h.http, runner: FakeRunner(), environment: [:], home: h.home, now: { clock.now })
        let snapshot = await fetcher.fetch(.claude)
        #expect(snapshot.state == .rateLimited(until: now.addingTimeInterval(600)))
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

    @Test func retryAfterZeroEndsTheCooldownImmediatelyAndRepeatsStayFlat() async throws {
        let h = try harness { _ in json(429, "{}", headers: ["Retry-After": "0"]) }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let first = await h.fetcher.fetch(.claude)
        #expect(first.state == .rateLimited(until: h.clock.now))
        let calls = h.usageCalls
        _ = await h.fetcher.fetch(.claude)
        #expect(h.usageCalls == calls + 1)

        h.http.respond { _ in json(429, "{}") }
        for _ in 0..<3 {
            h.clock.advance(1000)
            let snapshot = await h.fetcher.fetch(.claude)
            #expect(snapshot.state == .rateLimited(until: h.clock.now.addingTimeInterval(300)))
        }
    }

    @Test func successClearsTheCooldown() async throws {
        let h = try harness { _ in json(429, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = await h.fetcher.fetch(.claude)
        h.clock.advance(301)
        h.http.respond(Self.ok)
        #expect(await h.fetcher.fetch(.claude).state == .ok)
        let calls = h.usageCalls
        #expect(await h.fetcher.fetch(.claude).state == .ok)
        #expect(h.usageCalls > calls)
    }

    private func savedStore(_ home: URL, windows: [UsageWindow]) -> UsageStore {
        let store = UsageStore(url: home.appendingPathComponent("cache/usage.json"))
        var persisted = PersistedUsage()
        persisted.snapshots["claude"] = UsageSnapshot(
            provider: .claude, windows: windows, plan: "Pro", state: .ok, updatedAt: Date(timeIntervalSince1970: 1_799_990_000)
        )
        store.save(persisted)
        return store
    }

    private func relaunched(_ h: Harness, store: UsageStore) -> UsageFetcher {
        let clock = h.clock
        return UsageFetcher(http: h.http, loopbackHTTP: h.http, runner: FakeRunner(), environment: [:], home: h.home, now: { clock.now }, store: store)
    }

    @Test func persistedReadingIsExposedAndLaunchStillFetches() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let store = savedStore(h.home, windows: [UsageWindow(label: "5h", usedPercent: 77, resetsAt: h.clock.now.addingTimeInterval(600))])
        let fetcher = relaunched(h, store: store)
        #expect(await fetcher.persistedSnapshots()[.claude]?.windows.map(\.usedPercent) == [77])
        #expect(await fetcher.fetch(.claude).state == .ok)
        #expect(h.usageCalls == 1)
        #expect(store.load().snapshots["claude"]?.windows.map(\.usedPercent) == [10])
    }

    @Test func firstRateLimitAfterLaunchKeepsPersistedWindowsThatHaveNotReset() async throws {
        let h = try harness { _ in json(429, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let future = UsageWindow(label: "week", usedPercent: 60, resetsAt: h.clock.now.addingTimeInterval(3600))
        let past = UsageWindow(label: "5h", usedPercent: 90, resetsAt: h.clock.now.addingTimeInterval(-1))
        let fetcher = relaunched(h, store: savedStore(h.home, windows: [past, future]))
        let limited = await fetcher.fetch(.claude)
        #expect(limited.windows == [future])
        #expect(limited.plan == "Pro")
        #expect(limited.state == .rateLimited(until: h.clock.now.addingTimeInterval(300)))
    }

    @Test func rateLimitAfterLaunchAdoptsNothingWhenEveryWindowHasReset() async throws {
        let h = try harness { _ in json(429, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let past = UsageWindow(label: "5h", usedPercent: 90, resetsAt: h.clock.now.addingTimeInterval(-1))
        let limited = await relaunched(h, store: savedStore(h.home, windows: [past])).fetch(.claude)
        #expect(limited.windows.isEmpty)
    }

    @Test func successDiscardsThePersistedReadingBeforeALaterRateLimit() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        let saved = UsageWindow(label: "5h", usedPercent: 99, resetsAt: h.clock.now.addingTimeInterval(3600))
        let fetcher = relaunched(h, store: savedStore(h.home, windows: [saved]))
        _ = await fetcher.fetch(.claude)
        h.clock.advance(60)
        h.http.respond { _ in json(429, "{}") }
        #expect(await fetcher.fetch(.claude).windows.map(\.usedPercent) == [10])
    }

    @Test func hungProviderIsAbandonedAfterTheDeadlineKeepingLastGood() async throws {
        let late = TestGate()
        let finished = TestGate()
        let source = ScriptedSource([
            { _ in UsageReading(windows: [UsageWindow(label: "5h", usedPercent: 42)], plan: nil, extra: nil) },
            { _ in
                await late.wait()
                finished.open()
                throw UsageFailure.notSetUp("late")
            },
            { _ in throw UsageFailure.failed("later") }
        ])
        let dir = try makeHome()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageStore(url: dir.appendingPathComponent("usage.json"))
        let fetcher = UsageFetcher(
            sources: [.claude: source], now: { Date(timeIntervalSince1970: 1_800_000_000) }, store: store, timeout: 0.05)
        #expect(await fetcher.fetch(.claude).state == .ok)

        let timedOut = await fetcher.fetch(.claude)
        #expect(timedOut.state == .error("timed out after 0s"))
        #expect(timedOut.windows.map(\.usedPercent) == [42])

        // The abandoned refresh finishes with a notSetUp that must not wipe last-good or the file.
        late.open()
        await finished.wait()
        try await Task.sleep(for: .milliseconds(100))
        let after = await fetcher.fetch(.claude)
        #expect(after.state == .error("later"))
        #expect(after.windows.map(\.usedPercent) == [42])
        #expect(store.load().snapshots["claude"]?.windows.map(\.usedPercent) == [42])
        #expect(UsageFetcher.fetchTimeout == 120)
    }

    @Test func aKeychainPromptOutlivingTheDeadlineIsNotStackedByTheNextFetch() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = GatedRunner()
        let context = UsageContext(http: FakeHTTPClient(), loopbackHTTP: FakeHTTPClient(), runner: runner, environment: [:], home: home)
        let fetcher = UsageFetcher(
            sources: [.claude: ClaudeUsageSource(context: context)], now: { Date(timeIntervalSince1970: 1_800_000_000) }, timeout: 0.05)
        #expect(await fetcher.fetch(.claude).state == .error("timed out after 0s"))
        #expect(runner.calls.count == 1)
        #expect(await fetcher.fetch(.claude).state == .error("timed out after 0s"))
        #expect(runner.calls.count == 1)
        runner.release()
    }

    @Test func nonForcedFetchesReuseTheLatestAnswerForTheReuseInterval() async throws {
        let h = try harness { _ in json(429, "{}", headers: ["Retry-After": "0"]) }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let first = await h.fetcher.fetch(.claude)
        let calls = h.usageCalls
        #expect(calls > 0)
        for _ in 0..<5 {
            h.clock.advance(50)
            #expect(await h.fetcher.fetch(.claude, force: false) == first)
        }
        #expect(h.usageCalls == calls)
        h.clock.advance(120)
        _ = await h.fetcher.fetch(.claude, force: false)
        #expect(h.usageCalls > calls)
    }

    @Test func aForcedFetchIgnoresTheReusedAnswer() async throws {
        let h = try harness(Self.ok)
        defer { try? FileManager.default.removeItem(at: h.home) }
        _ = await h.fetcher.fetch(.claude)
        let calls = h.usageCalls
        _ = await h.fetcher.fetch(.claude, force: false)
        #expect(h.usageCalls == calls)
        _ = await h.fetcher.fetch(.claude)
        #expect(h.usageCalls > calls)
    }

    @Test func firstFetchFailureAfterLaunchKeepsThePersistedReadingWithTheErrorState() async throws {
        let h = try harness { _ in throw URLError(.notConnectedToInternet) }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let future = UsageWindow(label: "5h", usedPercent: 77, resetsAt: h.clock.now.addingTimeInterval(600))
        let store = savedStore(h.home, windows: [future])
        let shown = await relaunched(h, store: store).fetch(.claude)
        #expect(shown.state == .error("connection failed"))
        #expect(shown.windows == [future])
        #expect(shown.plan == "Pro")
        #expect(shown.updatedAt == Date(timeIntervalSince1970: 1_799_990_000))
        #expect(store.load().snapshots["claude"]?.windows == [future])
    }

    @Test func staleTokenAfterLaunchKeepsThePersistedReadingSinceItsTime() async throws {
        let h = try harness { _ in json(401, "{}") }
        defer { try? FileManager.default.removeItem(at: h.home) }
        let future = UsageWindow(label: "5h", usedPercent: 77, resetsAt: h.clock.now.addingTimeInterval(600))
        let shown = await relaunched(h, store: savedStore(h.home, windows: [future])).fetch(.claude)
        #expect(shown.windows == [future])
        #expect(shown.state == .stale(since: Date(timeIntervalSince1970: 1_799_990_000), reason: "open Claude Code"))
    }
}

/// Plays one closure per `load`, in order.
private final class ScriptedSource: UsageSource, @unchecked Sendable {
    typealias Step = @Sendable (Date) async throws -> UsageReading
    private let lock = NSLock()
    private var steps: [Step]

    init(_ steps: [Step]) { self.steps = steps }

    func load(now: Date) async throws -> UsageReading {
        let step = lock.withLock { steps.removeFirst() }
        return try await step(now)
    }
}

/// A one-shot latch: `wait` suspends until `open`.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if ready { continuation.resume() }
        }
    }
}

/// Never answers until released, like `security` waiting on an access prompt.
final class GatedRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let gate = TestGate()

    var calls: [[String]] { lock.withLock { recorded } }

    func release() { gate.open() }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { recorded.append(arguments) }
        await gate.wait()
        return ProcessResult(succeeded: false, status: 44)
    }
}

private extension UsageState {
    var until: Date {
        if case .rateLimited(let until) = self { return until }
        return .distantPast
    }
}
