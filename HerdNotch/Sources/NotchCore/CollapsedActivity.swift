import Foundation

/// What the collapsed notch shows beside the cutout, chosen by the user's priority: blocked agents, then
/// music, then active agents, then battery, then nothing.
public enum CollapsedActivity: Equatable, Sendable {
    case none
    case blocked(Int)
    /// `announce` is the "Title · Artist" line while a track-change announce is running, else `nil`.
    case playing(bundleID: String?, announce: String?)
    case agents(Int)
    case battery(percent: Int, charging: Bool)

    /// The now-playing facts the rule needs, already reduced from whichever source won the priority pick.
    public struct Track: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var bundleID: String?
        public var isPlaying: Bool

        public init(title: String, artist: String, bundleID: String?, isPlaying: Bool) {
            self.title = title
            self.artist = artist
            self.bundleID = bundleID
            self.isPlaying = isPlaying
        }
    }

    /// - Parameters:
    ///   - working: Working agents, counted with `blocked` for the agents case.
    ///   - nowPlaying: Paused music does not count as playing and falls through to agents.
    ///   - battery: `nil` on a Mac with no battery, which yields `.none` rather than a fake reading.
    ///   - announceUntil: End of the running track-change announce, `nil` when none is running.
    public static func decide(
        blocked: Int,
        working: Int,
        nowPlaying: Track?,
        battery: (percent: Int, charging: Bool)?,
        announceUntil: Date?,
        now: Date
    ) -> CollapsedActivity {
        if blocked > 0 { return .blocked(blocked) }
        if let track = nowPlaying, track.isPlaying {
            let announcing = announceUntil.map { now < $0 } ?? false
            return .playing(bundleID: track.bundleID, announce: announcing ? announceText(track) : nil)
        }
        if blocked + working > 0 { return .agents(blocked + working) }
        if let battery { return .battery(percent: battery.percent, charging: battery.charging) }
        return .none
    }

    private static func announceText(_ track: Track) -> String {
        track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)"
    }
}

/// Decides when a now-playing change deserves the wings' announce.
public enum AnnounceRule {
    /// Keyed on title and artist only: the services republish `NowPlaying` every second for position ticks,
    /// and those must not retrigger the announce. Only a playing track announces.
    public static func trackChanged(previous: CollapsedActivity.Track?, current: CollapsedActivity.Track?) -> Bool {
        guard let current, current.isPlaying else { return false }
        guard let previous else { return true }
        return previous.title != current.title || previous.artist != current.artist
    }
}
