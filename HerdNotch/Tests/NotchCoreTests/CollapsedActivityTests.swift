import Foundation
import Testing

@testable import NotchCore

struct CollapsedActivityTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let playing = CollapsedActivity.Track(title: "Song", artist: "Band", bundleID: "com.spotify.client", isPlaying: true)
    private var paused: CollapsedActivity.Track {
        var track = playing
        track.isPlaying = false
        return track
    }
    private let battery: (percent: Int, charging: Bool) = (87, true)

    private func decide(
        blocked: Int = 0, working: Int = 0, track: CollapsedActivity.Track? = nil,
        battery: (percent: Int, charging: Bool)? = nil, announceUntil: Date? = nil
    ) -> CollapsedActivity {
        CollapsedActivity.decide(
            blocked: blocked, working: working, nowPlaying: track, battery: battery,
            announceUntil: announceUntil, now: now)
    }

    @Test func blockedBeatsEverything() {
        #expect(decide(blocked: 2, working: 3, track: playing, battery: battery) == .blocked(2))
    }

    @Test func playingBeatsAgentsAndBattery() {
        #expect(decide(working: 3, track: playing, battery: battery) == .playing(bundleID: "com.spotify.client", announce: nil))
    }

    @Test func agentsBeatBatteryWhenNothingPlays() {
        #expect(decide(working: 3, battery: battery) == .agents(3))
    }

    @Test func batteryBeatsNothing() {
        #expect(decide(battery: battery) == .battery(percent: 87, charging: true))
    }

    @Test func nothingIsNone() {
        #expect(decide() == .none)
    }

    @Test func pausedMusicFallsThrough() {
        #expect(decide(working: 4, track: paused, battery: battery) == .agents(4))
        #expect(decide(track: paused, battery: battery) == .battery(percent: 87, charging: true))
        #expect(decide(track: paused) == .none)
    }

    @Test func noBatteryMeansNone() {
        #expect(decide(track: nil, battery: nil) == .none)
    }

    @Test func announceCarriesTextUntilExpiry() {
        let until = now.addingTimeInterval(3)
        #expect(decide(track: playing, announceUntil: until) == .playing(bundleID: "com.spotify.client", announce: "Song · Band"))
        #expect(decide(track: playing, announceUntil: now) == .playing(bundleID: "com.spotify.client", announce: nil))
        #expect(decide(track: playing, announceUntil: now.addingTimeInterval(-1)) == .playing(bundleID: "com.spotify.client", announce: nil))
    }

    @Test func announceDoesNotOutrankBlocked() {
        #expect(decide(blocked: 1, track: playing, announceUntil: now.addingTimeInterval(3)) == .blocked(1))
    }

    @Test func announceFiresOnTitleOrArtistChangeOnly() {
        var next = playing
        next.title = "Other"
        #expect(AnnounceRule.trackChanged(previous: playing, current: next))
        next = playing
        next.artist = "Someone"
        #expect(AnnounceRule.trackChanged(previous: playing, current: next))
    }

    @Test func positionOnlyOrPauseChangeDoesNotAnnounce() {
        #expect(!AnnounceRule.trackChanged(previous: playing, current: playing))
        #expect(!AnnounceRule.trackChanged(previous: playing, current: paused))
        #expect(!AnnounceRule.trackChanged(previous: nil, current: nil))
        #expect(!AnnounceRule.trackChanged(previous: playing, current: nil))
    }

    @Test func firstPlayingTrackAnnounces() {
        #expect(AnnounceRule.trackChanged(previous: nil, current: playing))
        #expect(!AnnounceRule.trackChanged(previous: nil, current: paused))
    }
}
