import Foundation
import Testing

@testable import UsageKit

@Suite struct UsageStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let snapshot = UsageSnapshot(
        provider: .claude,
        windows: [UsageWindow(label: "5h", usedPercent: 42, resetsAt: now.addingTimeInterval(600), periodSeconds: UsagePeriod.session)],
        plan: "Pro",
        extra: .claudeExtraUsage(usedUSD: 1.5, limitUSD: nil),
        state: .stale(since: now, reason: "x"),
        updatedAt: now
    )

    private func tempStore() -> UsageStore {
        UsageStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-\(UUID().uuidString)/nested/usage.json"))
    }

    @Test func codableRoundTripCoversEveryCase() throws {
        let states: [UsageState] = [.ok, .stale(since: Self.now, reason: "r"), .notSetUp(reason: "n"), .rateLimited(until: Self.now), .error("e")]
        let extras: [UsageExtra?] = [nil, .claudeExtraUsage(usedUSD: 1, limitUSD: 5), .codexCredits(credits: 3, usd: 1.25)]
        for (state, extra) in zip(states, extras + extras) {
            var snapshot = Self.snapshot
            snapshot.state = state
            snapshot.extra = extra
            let data = try JSONEncoder().encode(snapshot)
            #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data) == snapshot)
        }
    }

    @Test func saveThenLoadRoundTripsAndCreatesDirectory() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        var value = PersistedUsage()
        value.snapshots["claude"] = Self.snapshot
        store.save(value)
        #expect(store.load() == value)
    }

    @Test func missingFileLoadsEmpty() {
        #expect(tempStore().load() == PersistedUsage())
    }

    @Test func corruptFileIsIgnoredAndDeleted() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(store.load() == PersistedUsage())
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func savedJsonHoldsNoCredentialKeys() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        var value = PersistedUsage()
        value.snapshots["claude"] = Self.snapshot
        store.save(value)
        let text = try String(contentsOf: store.url, encoding: .utf8).lowercased()
        #expect(!text.contains("token"))
    }

    @Test func retryAfterParsing() {
        let now = Self.now
        func parsed(_ value: String) -> TimeInterval? {
            UsageParse.retryAfter(HTTPResponse(statusCode: 429, headers: ["Retry-After": value]), now: now)
        }
        #expect(parsed("0") == 0)
        #expect(parsed("45") == 45)
        #expect(parsed("900") == 900)
        #expect(parsed("-5") == nil)
        #expect(parsed("soon") == nil)
        #expect(UsageParse.retryAfter(HTTPResponse(statusCode: 429), now: now) == nil)
    }

    @Test func retryAfterHttpDateRoundsUpAndNeverGoesNegative() throws {
        let base = try #require(UsageParse.httpDate("Sat, 15 Jan 2027 08:00:00 GMT"))
        func parsed(now: Date) -> TimeInterval? {
            UsageParse.retryAfter(HTTPResponse(statusCode: 429, headers: ["Retry-After": "Sat, 15 Jan 2027 08:00:00 GMT"]), now: now)
        }
        #expect(parsed(now: base.addingTimeInterval(-90.4)) == 91)
        #expect(parsed(now: base.addingTimeInterval(30)) == 0)
    }
}
