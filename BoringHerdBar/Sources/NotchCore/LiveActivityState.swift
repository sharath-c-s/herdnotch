import Foundation

/// The time-dependent half of the collapsed wings: the track-change announce and the paused-state hold.
/// Pure, every method takes `now`, so the model only has to feed it and schedule wakeups at `nextWake`.
public struct LiveActivityState: Sendable {
    public static let announceSeconds: TimeInterval = 3
    public static let pausedHoldSeconds: TimeInterval = 1

    /// Last PLAYING track. Paused states never move it, so "A playing, B paused, B playing" still announces B.
    private var baseline: CollapsedActivity.Track?
    private var wasPlaying = false
    private var announceUntil: Date?
    private var holdUntil: Date?
    private var panelOpen = false

    public init() {}

    /// Feed the latest picked track (playing, paused or absent).
    public mutating func update(track: CollapsedActivity.Track?, now: Date) {
        if let track, track.isPlaying {
            if AnnounceRule.trackChanged(previous: baseline, current: track), !panelOpen {
                announceUntil = now.addingTimeInterval(Self.announceSeconds)
            }
            baseline = track
            wasPlaying = true
            holdUntil = nil
        } else if wasPlaying {
            // Absorbs momentary paused states between tracks; only the first paused update starts the clock.
            holdUntil = now.addingTimeInterval(Self.pausedHoldSeconds)
            wasPlaying = false
        }
    }

    /// Opening a panel also cancels a running announce so it cannot linger behind the open panel.
    public mutating func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open { announceUntil = nil }
    }

    public func activity(
        blocked: Int, working: Int, track: CollapsedActivity.Track?,
        battery: (percent: Int, charging: Bool)?, now: Date
    ) -> CollapsedActivity {
        var effective = track
        if track?.isPlaying != true, let holdUntil, now < holdUntil, var held = baseline {
            held.isPlaying = true
            effective = held
        }
        return CollapsedActivity.decide(
            blocked: blocked, working: working, nowPlaying: effective, battery: battery,
            announceUntil: announceUntil, now: now)
    }

    /// Earliest future instant at which `activity` can change on its own, `nil` when nothing is pending.
    public func nextWake(now: Date) -> Date? {
        [announceUntil, holdUntil].compactMap { $0 }.filter { $0 > now }.min()
    }
}
