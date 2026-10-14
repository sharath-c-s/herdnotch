import AppKit
import Foundation

/// Spotify now-playing and transport, BoringNotch-style: event-driven via `DistributedNotificationCenter`
/// for track/state changes, AppleScript for every command and for filling in whatever the notification
/// payload leaves out. No OAuth, no Web API, no like button, no playlist picker — those are a later phase;
/// this is the local, no-account now-playing tile and transport strip only.
///
/// **Event-driven, not polled.** `com.spotify.client.PlaybackStateChanged`, posted by Spotify.app itself on
/// every play/pause/track change, is what triggers a re-read; there is no repeating timer here at all.
/// Scrubbing while a track plays therefore shows the position as of the last such event (plus whatever a
/// user-initiated ``seek(to:)`` just set), not a live tick — matching this app's stated aversion to any
/// perpetual CPU cost for cosmetic smoothness (see `HerdStatusDot`'s own documentation on why a breathing
/// animation was removed from this codebase after being measured at up to 99% of a core).
///
/// AppleScript discipline matches `HerdHost/HerdTerminalWindowLocator` throughout: every script is wrapped
/// in `with timeout of 2 seconds`, and a fresh `NSAppleScript` is built per call, since `NSAppleScript` is
/// documented as not thread-safe.
///
/// Thread-safety: `@MainActor` for every published property, since `NotchContentView` reads them directly.
/// Every AppleScript execution is dispatched onto ``queue``, a private serial background queue, mirroring
/// `HerdFocusService`'s own discipline: `NSAppleScript.executeAndReturnError(_:)` can block for up to its 2
/// second timeout (longer still if Spotify itself is slow to answer), and that must never stall the main
/// run loop the notch's own open/close glitch-avoidance depends on running smoothly. `DispatchQueue.async`'s
/// closure parameter is `@Sendable`, which is what lets a closure literal written directly inside a
/// `@MainActor` method safely capture and dispatch work this way with no actor-isolation surprises — see
/// `RemindersService.fetchIncompleteReminders(store:predicate:completion:)`'s documentation for the crash
/// that arises when a completion-handler parameter is *not* `@Sendable` and this same "write the closure
/// directly in a `@MainActor` method" shape is used regardless.
@MainActor
final class SpotifyNowPlayingService: ObservableObject {
    /// A snapshot of Spotify's current track and transport state, reduced to what the notch surface renders.
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        /// Spotify's own `artwork url of current track`, an `https://i.scdn.co/...` URL `AsyncImage` can
        /// load directly. Empty when Spotify reports none (some tracks, notably local files, have no
        /// artwork URL).
        var artworkURLString: String
        var isPlaying: Bool
        var positionSeconds: Double
        var durationSeconds: Double
    }

    /// `nonisolated`: read from ``isSpotifyRunning``, itself `nonisolated` because it is called from
    /// ``queue``, off the main actor.
    private nonisolated static let bundleID = "com.spotify.client"
    private nonisolated static let playbackNotification = Notification.Name(
        "com.spotify.client.PlaybackStateChanged"
    )

    /// How often ``positionTimer`` re-queries Spotify while the notch panel is open and a track is playing,
    /// so the rail's scrub bar visibly advances instead of only updating on the next `PlaybackStateChanged`
    /// notification (which Spotify does not post on every second of playback).
    private nonisolated static let positionTickInterval: TimeInterval = 1

    /// What this service is allowed to say about Spotify's current playback, replacing an earlier
    /// `NowPlaying?` that conflated two different idle reasons into one `nil`: "Spotify is not running at
    /// all" (``notRunning``, the Ledger+Rail rail's "Spotify isn't running" + "Open Spotify" degraded state)
    /// and "Spotify is running but nothing is loaded" (``runningNoTrack``, that same rail's "Nothing
    /// playing" degraded state) call for different messages and, in the former case, a different action (the
    /// "Open Spotify" button ``openSpotify()`` backs) — a single `nil` could not tell a UI which one it was
    /// looking at.
    enum PlaybackState: Equatable {
        /// Spotify.app is not running.
        case notRunning
        /// Spotify.app is running, but has no current track (fresh launch, or a query that otherwise failed
        /// to answer — see ``queryNowPlaying()``'s own documentation for why those two are not distinguished
        /// further).
        case runningNoTrack
        /// Spotify.app is running with a current track loaded.
        case track(NowPlaying)
    }

    /// The current playback state. See ``PlaybackState`` for what each case means and which rail state it
    /// renders as.
    @Published private(set) var playbackState: PlaybackState = .notRunning

    /// Owns every AppleScript execution. `qos: .userInitiated`, matching `HerdFocusService`'s own queue: a
    /// transport button press is a direct user action waiting on a result, not background bookkeeping.
    private let queue = DispatchQueue(label: "com.boringherd.spotify", qos: .userInitiated)

    /// Re-queries ``queryNowPlaying()`` on ``Self/positionTickInterval`` while both a track is playing and
    /// this timer is running, so the rail's scrub position advances visibly during playback. Started by
    /// ``startPositionTicking()`` and stopped by ``stopPositionTicking()``, which `NotchWindowController`
    /// calls on this display's own expand/collapse — **never running while the panel is closed**, matching
    /// this app's stated aversion to any perpetual background cost (see this type's own documentation on why
    /// there is otherwise no polling here at all). The timer keeps running the whole time the panel is open
    /// even while paused (checking ``PlaybackState/track(_:)``'s `isPlaying` inside the handler, rather than
    /// stopping and restarting the timer itself on every play/pause), because a `DispatchSourceTimer` firing
    /// a no-op closure once a second is not a cost worth the bookkeeping of tearing it down and rebuilding it
    /// on every transport toggle.
    private var positionTimer: DispatchSourceTimer?

    /// Creates the service, subscribes to Spotify's own playback notification, and reads the current state
    /// once immediately (so a launch while Spotify is already playing shows something without waiting for
    /// the next notification).
    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.playbackNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // No `deinit` teardown of the distributed-notification observer, for the same reason
    // `RemindersService.startObservingChanges()` documents for its own `NotificationCenter` observer:
    // `NotchWindowController` builds exactly one `SpotifyNowPlayingService` and keeps it for the process's
    // entire lifetime, so there is no "this instance goes away early" moment this would ever need to guard.

    /// Re-reads Spotify's current track/state via AppleScript. Called on launch, on every
    /// `PlaybackStateChanged` notification, after every transport command, and on every ``positionTimer``
    /// tick; never polled on a timer while the panel is closed (see this type's own documentation).
    func refresh() {
        guard Self.isSpotifyRunning else {
            playbackState = .notRunning
            return
        }
        queue.async { [weak self] in
            let result = Self.queryNowPlaying()
            Task { @MainActor in
                guard let self else { return }
                self.playbackState = result.map(PlaybackState.track) ?? .runningNoTrack
            }
        }
    }

    /// Launches Spotify.app, backing the Ledger+Rail rail's "Open Spotify" button shown in
    /// ``PlaybackState/notRunning``.
    ///
    /// Does not itself refresh ``playbackState`` afterward: launching is asynchronous and Spotify takes a
    /// perceptible moment to come up, so there is no instant at which a refresh right after this call would
    /// reliably see anything past `.notRunning` anyway — the existing `PlaybackStateChanged` notification
    /// path (and, once the panel is open, ``positionTimer``) is what will pick the app up once it is
    /// actually running.
    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Starts (or restarts) ``positionTimer``. Called by `NotchWindowController` when this display's panel
    /// expands; see ``positionTimer``'s own documentation for the full open-only contract.
    func startPositionTicking() {
        stopPositionTicking()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.positionTickInterval, repeating: Self.positionTickInterval)
        timer.setEventHandler { [weak self] in
            guard let self, case .track(let now) = self.playbackState, now.isPlaying else { return }
            self.refresh()
        }
        positionTimer = timer
        timer.resume()
    }

    /// Cancels and forgets ``positionTimer``, if one is running. Called by `NotchWindowController` when this
    /// display's panel collapses (and is safe to call redundantly, for example on `suspend`).
    func stopPositionTicking() {
        positionTimer?.cancel()
        positionTimer = nil
    }

    /// Toggles play/pause.
    func playPause() { runTransportCommand("playpause") }

    /// Skips to the next track.
    func next() { runTransportCommand("next track") }

    /// Returns to the previous track.
    func previous() { runTransportCommand("previous track") }

    /// Scrubs to `seconds` into the current track, then re-queries so ``playbackState`` reflects the seek
    /// immediately rather than waiting for a `PlaybackStateChanged` notification Spotify does not always
    /// post for a scrub alone.
    ///
    /// - Parameter seconds: Target position, in seconds from the start of the track.
    func seek(to seconds: Double) {
        guard Self.isSpotifyRunning else { return }
        queue.async { [weak self] in
            Self.execute("""
            with timeout of 2 seconds
                tell application "Spotify" to set player position to \(seconds)
            end timeout
            """)
            let result = Self.queryNowPlaying()
            Task { @MainActor in self?.playbackState = result.map(PlaybackState.track) ?? .runningNoTrack }
        }
    }

    /// Runs one transport command (`playpause`, `next track`, `previous track`) and refreshes afterward, so
    /// a button press updates ``playbackState`` (in particular ``NowPlaying/isPlaying``) without waiting for
    /// Spotify's own notification to arrive.
    ///
    /// - Parameter spotifyCommand: An AppleScript statement valid inside `tell application "Spotify" to`.
    private func runTransportCommand(_ spotifyCommand: String) {
        guard Self.isSpotifyRunning else { return }
        queue.async { [weak self] in
            Self.execute("""
            with timeout of 2 seconds
                tell application "Spotify" to \(spotifyCommand)
            end timeout
            """)
            let result = Self.queryNowPlaying()
            Task { @MainActor in self?.playbackState = result.map(PlaybackState.track) ?? .runningNoTrack }
        }
    }

    /// Whether Spotify.app is currently running. Checked before every AppleScript call: scripting an
    /// application that is not running would launch a fresh, unplayed instance of it rather than reveal
    /// anything, the same reasoning `HerdTerminalWindowLocator.raise(sessionName:socketPath:bundleId:)`
    /// documents for its own terminal-running check.
    private nonisolated static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Queries Spotify's current track, artist, artwork URL, playing state, position and duration in one
    /// AppleScript round trip. Runs off the main actor (see this type's own documentation).
    ///
    /// Fields are joined with a literal `"|||"` delimiter rather than a newline built from an escape
    /// sequence: AppleScript string literals do not interpret `\n` as a control character, so a delimiter
    /// has to either be a plain, practically-never-appears-in-a-track-title string like this one, or reach
    /// for a scripting-addition constant (`ASCII character 10`) this file has no other reason to depend on.
    /// Position and duration are read as integer milliseconds (`round (player position * 1000)`, and
    /// `duration of current track`, already milliseconds) rather than as fractional seconds specifically to
    /// dodge locale-dependent decimal-separator formatting in AppleScript's `as string` coercion — an
    /// integer's string form has no separator to get wrong.
    ///
    /// - Returns: A snapshot, or `nil` when Spotify is not running or the script otherwise fails (most
    ///   commonly: Spotify is running but has no track loaded, in which case `current track` itself errors).
    ///   Either way this is the same idle state as "not running" to this service's caller; there is nothing
    ///   further to distinguish for a now-playing tile.
    ///
    /// `nonisolated`: called only from inside a ``queue`` closure, never from the main actor. Without this,
    /// the class's own `@MainActor` isolation would apply to this static member too (static members of an
    /// actor-isolated type are isolated by default, same as instance members), silently turning every call
    /// into an implicit main-actor hop and defeating the whole point of dispatching AppleScript work onto
    /// ``queue`` in the first place — the exact "closure quietly inherits isolation it should not have"
    /// trap this type's own documentation calls out for the completion-handler case, here on the calling
    /// side instead.
    private nonisolated static func queryNowPlaying() -> NowPlaying? {
        guard isSpotifyRunning else { return nil }
        let source = """
        with timeout of 2 seconds
            tell application "Spotify"
                set trackName to name of current track
                set trackArtist to artist of current track
                set artURL to artwork url of current track
                set playingFlag to (player state is playing)
                set posMs to round (player position * 1000)
                set durMs to duration of current track
                return trackName & "|||" & trackArtist & "|||" & artURL & "|||" & \
                    (playingFlag as string) & "|||" & (posMs as string) & "|||" & (durMs as string)
            end tell
        end timeout
        """
        guard let raw = execute(source) else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count == 6,
            let positionMs = Double(parts[4]),
            let durationMs = Double(parts[5])
        else { return nil }
        return NowPlaying(
            title: parts[0],
            artist: parts[1],
            artworkURLString: parts[2],
            isPlaying: parts[3] == "true",
            positionSeconds: positionMs / 1000,
            durationSeconds: durationMs / 1000
        )
    }

    /// Executes one AppleScript source string with a fresh `NSAppleScript` instance, mirroring
    /// `HerdTerminalWindowLocator.executeOnce(_:)`'s discipline exactly: a new instance per call (never
    /// shared, since `NSAppleScript` is documented as not thread-safe), and every error — Automation denial,
    /// a 2 second timeout, "no track is playing" — is swallowed into `nil` rather than surfaced, since this
    /// service's only observable states are "here is a track" and "idle", with no error banner of its own to
    /// report a script failure into.
    ///
    /// - Parameter source: Complete AppleScript source, already wrapped in its own `with timeout of 2
    ///   seconds`.
    /// - Returns: The script's string result, or `nil` on any failure.
    @discardableResult
    private nonisolated static func execute(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let descriptor = script?.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        return descriptor?.stringValue
    }
}
