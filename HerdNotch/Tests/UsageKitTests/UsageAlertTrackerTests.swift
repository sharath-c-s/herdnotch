import Foundation
import Testing

@testable import UsageKit

@Suite struct UsageAlertTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        _ percent: Double, resetsAt: Date? = nil, label: String = "Session", provider: UsageProvider = .claude,
        state: UsageState = .ok
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, windows: [UsageWindow(label: label, usedPercent: percent, resetsAt: resetsAt)],
            state: state, updatedAt: now)
    }

    private func kinds(_ events: [UsageEvent]) -> [UsageEvent.Kind] { events.map(\.kind) }

    @Test func firstReadingNeverFiresEvenWhenAlreadyHigh() {
        var tracker = UsageAlertTracker()
        #expect(tracker.update(snapshot(97), warn: 80, critical: 95, now: now).isEmpty)
        // Already marked critical, so staying high stays quiet.
        #expect(tracker.update(snapshot(98), warn: 80, critical: 95, now: now).isEmpty)
    }

    @Test func upwardCrossingsFireWarningThenCriticalOnce() {
        var tracker = UsageAlertTracker()
        _ = tracker.update(snapshot(10), warn: 80, critical: 95, now: now)
        #expect(kinds(tracker.update(snapshot(82), warn: 80, critical: 95, now: now)) == [.warning])
        #expect(kinds(tracker.update(snapshot(96), warn: 80, critical: 95, now: now)) == [.critical])
        #expect(tracker.update(snapshot(99), warn: 80, critical: 95, now: now).isEmpty)
    }

    @Test func wobbleAroundWarnDoesNotRefire() {
        var tracker = UsageAlertTracker()
        _ = tracker.update(snapshot(70), warn: 80, critical: 95, now: now)
        #expect(kinds(tracker.update(snapshot(80), warn: 80, critical: 95, now: now)) == [.warning])
        for percent in [79.0, 81, 79, 80, 78] {
            #expect(tracker.update(snapshot(percent), warn: 80, critical: 95, now: now).isEmpty)
        }
    }

    @Test func fiftyPointDropResetsAndAllowsANewWarning() {
        var tracker = UsageAlertTracker()
        _ = tracker.update(snapshot(10), warn: 80, critical: 95, now: now)
        _ = tracker.update(snapshot(90), warn: 80, critical: 95, now: now)
        #expect(kinds(tracker.update(snapshot(20), warn: 80, critical: 95, now: now)) == [.reset])
        #expect(kinds(tracker.update(snapshot(85), warn: 80, critical: 95, now: now)) == [.warning])
    }

    @Test func windowRollResetsOnlyAfterAWarning() {
        var tracker = UsageAlertTracker()
        let firstReset = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(120)
        _ = tracker.update(snapshot(10, resetsAt: firstReset), warn: 80, critical: 95, now: now)
        // Rolled without ever warning: no reset event.
        #expect(tracker.update(snapshot(5, resetsAt: later + 3600), warn: 80, critical: 95, now: later).isEmpty)

        _ = tracker.update(snapshot(90, resetsAt: later + 3600), warn: 80, critical: 95, now: later)
        let rolled = tracker.update(snapshot(85, resetsAt: later + 7200), warn: 80, critical: 95, now: later + 3601)
        #expect(kinds(rolled) == [.reset, .warning])
    }

    @Test func staleSnapshotsAndUntrackedWindowsAreIgnored() {
        var tracker = UsageAlertTracker()
        _ = tracker.update(snapshot(10), warn: 80, critical: 95, now: now)
        #expect(tracker.update(snapshot(99, state: .error("x")), warn: 80, critical: 95, now: now).isEmpty)
        #expect(tracker.update(snapshot(99, label: "Opus"), warn: 80, critical: 95, now: now).isEmpty)
        #expect(tracker.update(snapshot(99, provider: .openCode), warn: 80, critical: 95, now: now).isEmpty)
    }

    @Test func forgettingAProviderMakesItsNextReadingAFirstReading() {
        var tracker = UsageAlertTracker()
        _ = tracker.update(snapshot(10), warn: 80, critical: 95, now: now)
        tracker.forget(.claude)
        #expect(tracker.update(snapshot(90), warn: 80, critical: 95, now: now).isEmpty)
    }
}
