import Foundation
import Testing

@testable import UsageKit

@Suite struct UsageStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func limited(_ seconds: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, state: .rateLimited(until: now.addingTimeInterval(seconds)), updatedAt: now)
    }

    private func ok(age: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, state: .ok, updatedAt: now.addingTimeInterval(-age))
    }

    @Test func rateLimitRoundsTheRetryUpToWholeMinutes() {
        #expect(UsageStatus.note(for: limited(60), now: now) == "rate limited, retry ~1m")
        #expect(UsageStatus.note(for: limited(61), now: now) == "rate limited, retry ~2m")
        #expect(UsageStatus.note(for: limited(0), now: now) == "rate limited")
        #expect(UsageStatus.note(for: limited(-30), now: now) == "rate limited")
        #expect(UsageStatus.isDimmed(limited(0), now: now))
    }

    @Test func anOkReadingTenMinutesOldIsOutdatedAndDimmed() {
        let old = ok(age: 600)
        #expect(UsageStatus.note(for: old, now: now) == "updated 10m ago")
        #expect(UsageStatus.isDimmed(old, now: now))
    }

    @Test func anOkReadingJustUnderTenMinutesIsFresh() {
        let fresh = ok(age: 599)
        #expect(UsageStatus.note(for: fresh, now: now) == nil)
        #expect(!UsageStatus.isDimmed(fresh, now: now))
    }

    @Test func otherStatesHaveTheirOwnNotes() {
        #expect(UsageStatus.note(for: nil, now: now) == "loading")
        #expect(UsageStatus.note(for: UsageSnapshot(provider: .codex, state: .notSetUp(reason: "x"), updatedAt: now), now: now) == "not set up")
        let stale = UsageSnapshot(provider: .claude, state: .stale(since: now.addingTimeInterval(-3 * 3600 - 120), reason: "r"), updatedAt: now)
        #expect(UsageStatus.note(for: stale, now: now) == "updated 3h 2m ago")
        #expect(UsageStatus.isDimmed(stale, now: now))
        let failed = UsageSnapshot(provider: .claude, state: .error("connection failed"), updatedAt: now)
        #expect(UsageStatus.note(for: failed, now: now) == "connection failed")
        #expect(!UsageStatus.isDimmed(failed, now: now))
    }
}
