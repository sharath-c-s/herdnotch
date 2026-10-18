import AppKit
import Combine
import Foundation
import HerdKit
import NotchCore

/// The single now-playing source the notch surfaces agree on, so the card and the collapsed wings never
/// disagree about which app is "playing".
enum NowPlayingPick {
    case spotify(SpotifyNowPlayingService.NowPlaying)
    case system(SystemNowPlayingService.NowPlaying)

    /// Priority: Spotify playing, system playing, Spotify paused, system paused. Spotify wins ties because
    /// its AppleScript surface is richer (precise seek, artwork URL).
    static func pick(
        spotify: SpotifyNowPlayingService.PlaybackState,
        system: SystemNowPlayingService.PlaybackState
    ) -> NowPlayingPick? {
        if case .track(let now) = spotify, now.isPlaying { return .spotify(now) }
        if case .track(let now) = system, now.isPlaying { return .system(now) }
        if case .track(let now) = spotify { return .spotify(now) }
        if case .track(let now) = system { return .system(now) }
        return nil
    }

    /// `nil` when MediaRemote could not attribute the entry to an app.
    var sourceBundleID: String? {
        switch self {
        case .spotify: return "com.spotify.client"
        case .system(let now): return now.sourceBundleID
        }
    }

    var track: CollapsedActivity.Track {
        switch self {
        case .spotify(let now):
            return .init(title: now.title, artist: now.artist, bundleID: sourceBundleID, isPlaying: now.isPlaying)
        case .system(let now):
            return .init(title: now.title, artist: now.artist, bundleID: sourceBundleID, isPlaying: now.isPlaying)
        }
    }
}

/// App icons for the wings, looked up once per bundle id (including misses).
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = .some(icon)
        return icon
    }
}

/// Feeds the collapsed notch's wings: folds agents, now playing and battery into one
/// ``CollapsedActivity`` and runs the timed track-change announce and paused hold (see ``LiveActivityState``). One instance serves every display.
@MainActor
final class LiveActivityModel: ObservableObject {
    @Published private(set) var activity: CollapsedActivity = .none

    /// Set by the controller while any panel is open: suppresses new announces and cancels a running one.
    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            state.setPanelOpen(isPanelOpen)
            refresh()
        }
    }

    private struct Inputs {
        var counts = StatusCounts()
        var spotify: SpotifyNowPlayingService.PlaybackState = .notRunning
        var system: SystemNowPlayingService.PlaybackState = .notRunning
        var batteryPercent: Int?
        var charging = false
    }

    private var inputs = Inputs()
    private var state = LiveActivityState()
    private var wakeTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        herdModel: NotchHerdModel,
        spotifyService: SpotifyNowPlayingService,
        systemNowPlayingService: SystemNowPlayingService,
        batteryService: BatteryService
    ) {
        // `@Published` emits before the new value is stored, so each sink carries the value itself and hops
        // one main-actor turn, the same idiom the controller's own sinks use.
        herdModel.$snapshot.map(\.counts).removeDuplicates().sink { [weak self] counts in
            Task { @MainActor in self?.apply { $0.counts = counts } }
        }.store(in: &cancellables)
        spotifyService.$playbackState.removeDuplicates().sink { [weak self] state in
            Task { @MainActor in self?.apply { $0.spotify = state } }
        }.store(in: &cancellables)
        systemNowPlayingService.$playbackState.removeDuplicates().sink { [weak self] state in
            Task { @MainActor in self?.apply { $0.system = state } }
        }.store(in: &cancellables)
        batteryService.$percent.combineLatest(batteryService.$isCharging).sink { [weak self] percent, charging in
            Task { @MainActor in
                self?.apply {
                    $0.batteryPercent = percent
                    $0.charging = charging
                }
            }
        }.store(in: &cancellables)
    }

    private func apply(_ change: (inout Inputs) -> Void) {
        change(&inputs)
        state.update(track: NowPlayingPick.pick(spotify: inputs.spotify, system: inputs.system)?.track, now: Date())
        refresh()
    }

    /// Recomputes the wings and re-arms the single wakeup for the next announce or hold expiry.
    private func refresh() {
        let now = Date()
        let next = state.activity(
            blocked: inputs.counts.blocked,
            working: inputs.counts.working,
            track: NowPlayingPick.pick(spotify: inputs.spotify, system: inputs.system)?.track,
            battery: inputs.batteryPercent.map { ($0, inputs.charging) },
            now: now
        )
        if next != activity { activity = next }
        wakeTask?.cancel()
        wakeTask = nil
        guard let wake = state.nextWake(now: now) else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wake.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
