import Foundation
import Testing

@testable import NotchCore

struct LiveActivityStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func track(_ title: String, playing: Bool = true) -> CollapsedActivity.Track {
        .init(title: title, artist: "Band", bundleID: "app", isPlaying: playing)
    }
    private func activity(_ state: LiveActivityState, _ track: CollapsedActivity.Track?, at now: Date) -> CollapsedActivity {
        state.activity(blocked: 0, working: 2, track: track, battery: nil, now: now)
    }

    @Test func announcesOnTrackChangeWhilePlaying() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        state.update(track: track("B"), now: t0.addingTimeInterval(10))
        #expect(activity(state, track("B"), at: t0.addingTimeInterval(11)) == .playing(bundleID: "app", announce: "B · Band"))
    }

    @Test func pausedInterimStillAnnouncesNextTrack() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        state.update(track: track("B", playing: false), now: t0.addingTimeInterval(10))
        state.update(track: track("B"), now: t0.addingTimeInterval(10.5))
        #expect(activity(state, track("B"), at: t0.addingTimeInterval(11)) == .playing(bundleID: "app", announce: "B · Band"))
    }

    @Test func positionOnlyChangeNeitherAnnouncesNorChangesOutput() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        let later = t0.addingTimeInterval(30)
        let before = activity(state, track("A"), at: later)
        state.update(track: track("A"), now: later)
        #expect(activity(state, track("A"), at: later) == before)
        #expect(before == .playing(bundleID: "app", announce: nil))
        #expect(state.nextWake(now: later) == nil)
    }

    @Test func openPanelSuppressesAndCancelsAnnounce() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        state.setPanelOpen(true)
        state.update(track: track("B"), now: t0.addingTimeInterval(10))
        #expect(activity(state, track("B"), at: t0.addingTimeInterval(11)) == .playing(bundleID: "app", announce: nil))
        state.setPanelOpen(false)
        state.update(track: track("C"), now: t0.addingTimeInterval(20))
        #expect(activity(state, track("C"), at: t0.addingTimeInterval(21)) == .playing(bundleID: "app", announce: "C · Band"))
        state.setPanelOpen(true)
        #expect(activity(state, track("C"), at: t0.addingTimeInterval(21)) == .playing(bundleID: "app", announce: nil))
    }

    @Test func pausedIsHeldOneSecondThenFallsThrough() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        let paused = track("A", playing: false)
        let pauseAt = t0.addingTimeInterval(60)
        state.update(track: paused, now: pauseAt)
        #expect(activity(state, paused, at: pauseAt.addingTimeInterval(0.9)) == .playing(bundleID: "app", announce: nil))
        #expect(activity(state, paused, at: pauseAt.addingTimeInterval(1.0)) == .agents(2))
        #expect(state.nextWake(now: pauseAt) == pauseAt.addingTimeInterval(1))
    }

    @Test func announceExpiresAndSchedulesWake() {
        var state = LiveActivityState()
        state.update(track: track("A"), now: t0)
        #expect(state.nextWake(now: t0) == t0.addingTimeInterval(3))
        #expect(activity(state, track("A"), at: t0.addingTimeInterval(3)) == .playing(bundleID: "app", announce: nil))
        #expect(state.nextWake(now: t0.addingTimeInterval(3)) == nil)
    }
}
