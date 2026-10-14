import AppKit
import Foundation

/// System-wide now-playing (Music, Safari/Chrome/Arc web audio and video, Podcasts — anything that
/// publishes to the system's Now Playing widget) via the private `MediaRemote` framework, so the notch's
/// now-playing card is not limited to Spotify's own AppleScript surface.
///
/// ## The private-entitlement question this file exists to answer — REVISED
///
/// An earlier revision of this file's own documentation claimed the read-gate macOS is widely reported to
/// apply to `MRMediaRemoteGetNowPlayingInfo` did not block this app on this machine, based on a probe that
/// ran as a **completely unsigned, uncompiled `swift <file>.swift` script**. That probe's conclusion did not
/// generalize to `HerdNotch.app` itself, and a follow-up, more targeted probe overturned it:
///
/// - A trivial `MRMediaRemoteGetNowPlayingInfo` probe, **compiled** with `swiftc` and then ad-hoc-signed
///   with `codesign --sign -` (the exact signing `build-notch.sh` applies to `HerdNotch.app`), returned an
///   **empty dictionary** (`keys=0`) while Spotify was actively playing a track.
/// - The **identical source**, run interpreted via `xcrun swift <file>.swift` (never compiled, never
///   codesigned by anything of ours — `xcrun`/`swift` carry Apple's own signature), returned a full 18-key
///   dictionary for that same track (title "Barely Legal", artist "The Strokes", 600×600 artwork bytes,
///   elapsed time, and more).
///
/// **Confirmed root cause**: on macOS 26.2, `MRMediaRemoteGetNowPlayingInfo`'s read gate keys off the
/// *calling process's own code signature*, not anything about the source file. `HerdNotch.app` is ad-hoc
/// signed (`build-notch.sh`'s `codesign --sign -`), so its own in-process `dlopen`/`dlsym` call to this
/// symbol is, and always will be, handed an empty dictionary — no amount of retrying or re-registering fixes
/// that from inside this process. Running the read through an Apple-signed interpreter is what dodges the
/// gate; compiling that same interpreted code into a binary and ad-hoc-signing it (what `build-notch.sh` does
/// to everything else in this app) reproduces the empty-dictionary problem, not the fix — so the fix cannot
/// be "just call this from Swift code that ships inside `HerdNotch.app`" at all. This is the same reason
/// BoringNotch ships an external Apple-signed `mediaremote-adapter` helper rather than reading `MediaRemote`
/// in-process.
///
/// **The fix**: `HelperScripts/mediaremote-helper.swift`, a loose `.swift` source file bundled into
/// `HerdNotch.app/Contents/Resources` by `build-notch.sh` and deliberately never compiled by anything —
/// compiling it would silently reintroduce the exact gate it exists to route around. ``startHelper()``
/// launches it as a long-lived subprocess via `/usr/bin/xcrun swift <path>`, reads one JSON line per
/// now-playing update from its stdout, and applies each line to ``playbackState``. See that script's own
/// top-of-file documentation for its exact output contract and for why it uses raw `FileHandle` writes
/// rather than `print` (stdout buffering).
///
/// **`MRMediaRemoteSendCommand` is a separate, opposite finding**: empirically, on this machine, it is
/// **not** gated by the caller's code signature at all. An ad-hoc-signed compiled binary calling
/// `MRMediaRemoteSendCommand(2, nil)` (toggle play/pause) toggled Spotify's actual playback state exactly as
/// reliably as the identical call made through the Apple-signed `xcrun swift` interpreter — the one variable
/// that mattered in testing was keeping the calling process's run loop alive long enough for the
/// asynchronous, XPC-backed command to actually be delivered before the process exited, which is a non-issue
/// for `HerdNotch.app` itself (a long-lived GUI app whose run loop is always pumping). ``sendCommand(_:)``
/// therefore still calls `MRMediaRemoteSendCommand` directly, in-process, completely unchanged from before
/// this revision — only the *read* path needed the helper.
///
/// ## Robustness: the helper is not load-bearing for "the app doesn't crash"
///
/// If `/usr/bin/xcrun` is missing, the bundled script is missing (e.g. running via `swift run` outside
/// `build-notch.sh`'s app bundle, which carries no `Contents/Resources`), or the subprocess exits, this
/// falls back to the pre-existing direct `dlopen`/`MRMediaRemoteGetNowPlayingInfo` call below — which, per
/// the finding above, is expected to read back empty on this machine, but costs nothing and never crashes.
/// ``helperActive`` is what gates which of the two read paths is authoritative at any moment; see its own
/// documentation.
///
/// `kMRMediaRemoteNowPlayingInfoDidChangeNotification` firing reliably was never independently reverified in
/// this revision — the helper script's own ~1-second heartbeat (mirroring this type's pre-existing
/// ``positionTimer`` hedge) is what makes that unconfirmed claim not matter either way.
///
/// Seeking goes through the perl adapter's `seek` command (``seek(to:)``); the in-process path has none.
///
/// ## Primary read path: perl adapter
///
/// ``NowPlayingAdapterProcess`` runs ungive/mediaremote-adapter's perl script (Apple-signed `/usr/bin/perl`,
/// no Xcode CLT needed) and ``handleAdapterLine(_:)`` applies its stream. The xcrun helper described above
/// stays as a fallback: it starts only when the adapter is not bundled or its child exits, and is stopped
/// again once the adapter emits a line.
///
/// ## Isolation
///
/// Every `dlopen`/`dlsym`/private-framework/subprocess-launch detail lives in this file (plus the bundled
/// helper script it launches) alone, per this spike's own constraint — `NotchContentView` and
/// `NotchWindowController` see only ``NowPlaying``/``PlaybackState``, plain value types with no
/// private-framework or subprocess fingerprints on them.
///
/// ## Thread-safety
///
/// `@MainActor` for every published property, matching `SpotifyNowPlayingService`. `MediaRemote`'s own
/// completion-handler APIs take a `DispatchQueue` to call back on; ``callbackQueue`` (a private serial
/// background queue, never `.main`) is what is handed to them, so a slow or never-firing MediaRemote
/// completion can never block the main run loop the notch's own glitch-avoidance depends on — the same
/// reasoning `SpotifyNowPlayingService` documents for dispatching its own AppleScript calls off-main. The
/// helper subprocess's stdout `readabilityHandler` runs on a `Foundation`-owned background queue for the
/// identical reason, and hops to `@MainActor` (via `Task { @MainActor in ... }`) only to apply a parsed line
/// to ``playbackState``.
@MainActor
final class SystemNowPlayingService: ObservableObject {
    /// A snapshot of the system's current now-playing entry, reduced to what the notch surface renders.
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        /// Raw artwork bytes from `kMRMediaRemoteNowPlayingInfoArtworkData`, if the now-playing app supplied
        /// any — unlike Spotify's own `artwork url of current track`, MediaRemote hands back bytes, not a
        /// URL, so the card renders this via `NSImage(data:)` rather than `AsyncImage(url:)`. `nil` when the
        /// source app (as with the browser tab the probe observed) supplied no artwork at all.
        var artworkData: Data?
        var isPlaying: Bool
        var positionSeconds: Double
        var durationSeconds: Double
        /// The bundle identifier MediaRemote attributes this now-playing entry to, read via
        /// `MRMediaRemoteGetNowPlayingApplicationPID` → `NSRunningApplication.bundleIdentifier`. `nil` when
        /// the PID could not be resolved to a running application (a process that has already quit between
        /// the two async calls, in practice vanishingly rare).
        var sourceBundleID: String?
    }

    /// What this service is allowed to say about the system's now-playing state — only two cases, unlike
    /// `SpotifyNowPlayingService.PlaybackState`'s three: there is no single "app" to be not-running here
    /// (this is system-wide), so there is nothing analogous to Spotify's own `.notRunning` "open Spotify"
    /// affordance for this source.
    enum PlaybackState: Equatable {
        /// MediaRemote currently has no now-playing entry for anything on the system.
        case notRunning
        /// MediaRemote has a current now-playing entry, from whichever app most recently claimed it.
        case track(NowPlaying)
    }

    /// The current system-wide playback state.
    @Published private(set) var playbackState: PlaybackState = .notRunning

    /// The private framework's on-disk path. Present as a real path here purely for `dlopen`'s benefit — on
    /// modern macOS this file does not actually exist as a standalone Mach-O on disk (it lives only in the
    /// dyld shared cache; `file`/`nm` against this path report a broken symlink), but `dlopen` still
    /// resolves it correctly at runtime by consulting the shared cache, which is exactly what the probe this
    /// type's own documentation describes confirmed.
    private nonisolated static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    /// `MRMediaRemoteGetNowPlayingInfo`'s C signature: takes the queue to call back on, then an
    /// `[String: Any]` info dictionary (empty, never `nil`, when there is nothing now playing).
    private typealias GetNowPlayingInfoFn = @convention(c) (
        DispatchQueue, @escaping ([String: Any]) -> Void
    ) -> Void

    /// `MRMediaRemoteGetNowPlayingApplicationPID`'s C signature.
    private typealias GetApplicationPIDFn = @convention(c) (
        DispatchQueue, @escaping (Int32) -> Void
    ) -> Void

    /// `MRMediaRemoteRegisterForNowPlayingNotifications`'s C signature: takes only the queue every
    /// subsequently-posted now-playing notification should be delivered on.
    private typealias RegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void

    /// `MRMediaRemoteSendCommand`'s C signature: an `MRMediaRemoteCommand` (an `NSInteger`-backed enum, so
    /// `Int` on 64-bit) plus an optional options dictionary, returning whether the command was accepted.
    private typealias SendCommandFn = @convention(c) (Int, NSDictionary?) -> Bool

    /// The well-known, stable-across-releases `MRMediaRemoteCommand` values every open-source `MediaRemote`
    /// wrapper this spike is aware of agrees on. See this type's own documentation for why seek's command
    /// code is deliberately *not* included here.
    private enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// The notification `MediaRemote` posts to `NotificationCenter.default` (not distributed — unlike
    /// Spotify's own `PlaybackStateChanged`, this is a same-process, in-process-only notification) whenever
    /// the system's now-playing info changes, once ``registerForNotifications()`` has been called. A plain
    /// string literal rather than something resolved via `dlsym`: this constant's name and value are widely
    /// documented and used verbatim by every known open-source `MediaRemote` wrapper, so hardcoding it here
    /// avoids the extra complexity of `dlsym`-ing an exported string constant for a value that is not
    /// expected to change.
    private nonisolated static let nowPlayingInfoDidChangeNotification = Notification.Name(
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
    )

    /// Owns every `MediaRemote` completion-handler call. `qos: .userInitiated`, mirroring
    /// `SpotifyNowPlayingService.queue`: a transport button press is a direct user action waiting on a
    /// result, not background bookkeeping.
    private let callbackQueue = DispatchQueue(label: "com.boringherd.medaremote", qos: .userInitiated)

    /// The `dlopen` handle for `MediaRemote`, or `nil` if it could not be opened at all (never observed in
    /// the probe, but guarded rather than force-unwrapped since this is still a private, unsupported
    /// framework that could vanish or move in a future OS release).
    ///
    /// `nonisolated(unsafe)`, not plain `nonisolated`: `UnsafeMutableRawPointer` is not `Sendable`, and
    /// Swift 6's strict concurrency checking will not let a `nonisolated` static `let` hold one. This is
    /// safe regardless — the handle is set once at first access and never mutated afterward, the same
    /// "immutable after first use" shape `dlopen`'s own caching makes true of any handle to the same path.
    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_NOW)

    /// Re-queries ``refresh()`` on the same one-second cadence `SpotifyNowPlayingService.positionTimer`
    /// uses, and for the identical reason: a visible, live-advancing scrub position while the panel is open,
    /// as a hedge against ``nowPlayingInfoDidChangeNotification`` not firing as often as playback actually
    /// advances (or, per this type's own "not verified end-to-end" caveat, not firing at all). Started by
    /// ``startPositionTicking()`` and stopped by ``stopPositionTicking()``, which `NotchWindowController`
    /// calls on every display's own expand/collapse, exactly mirroring `SpotifyNowPlayingService`'s own
    /// contract — **never running while every panel is closed**.
    private var positionTimer: DispatchSourceTimer?

    /// The Apple-signed-interpreter helper subprocess (`HelperScripts/mediaremote-helper.swift`, launched via
    /// `/usr/bin/xcrun swift`), or `nil` before ``startHelper()`` runs, if it could not be launched at all, or
    /// after it has exited (its `terminationHandler` clears this). Kept only so ``terminateHelper()`` has
    /// something to `terminate()` on app quit — nothing else here reads the process object itself.
    private var helperProcess: Process?

    /// True once ``handleHelperLine(_:)`` has successfully parsed at least one JSON line from the helper
    /// subprocess. While true, ``refresh()``'s own direct, in-process `dlopen` read (confirmed empty on this
    /// machine per this type's own top-of-file documentation) is skipped entirely, so a definitely-empty
    /// direct read can never race a real helper-derived value and stomp it back to ``PlaybackState/notRunning``.
    /// Reset to `false` by ``terminateHelper()``'s call site in the subprocess's own `terminationHandler`, so a
    /// helper crash falls back to the direct read (empty, but harmless) rather than freezing on stale state.
    private var helperActive = false

    /// The perl + `MediaRemoteAdapter.framework` stream child (see ``NowPlayingAdapterProcess``), or `nil`
    /// when perl, the script or the framework is not bundled. It is the primary read path; the xcrun helper
    /// above only runs while the adapter has not produced output.
    private var adapter: NowPlayingAdapterProcess?

    /// True once the adapter emitted a valid line this run. Takes priority over ``helperActive`` and the
    /// direct read in ``refresh()``, and is cleared when the adapter child exits.
    private var adapterActive = false

    /// The adapter's merged now-playing dictionary (`--micros` keys). The stream sends diffs by default, so
    /// this is the accumulated state, not the last line.
    private var adapterPayload: [String: Any] = [:]

    /// Decoded artwork for ``adapterPayload``, plus the base64 text it came from so an identical re-send is
    /// not decoded again.
    private var adapterArtwork: Data?
    private var adapterArtworkSource: String?

    /// Creates the service: launches the read-only helper subprocess (see this type's own top-of-file
    /// documentation for why), registers for `MediaRemote`'s own in-process change notifications as the
    /// fallback path's event source, and reads the current state once immediately via whichever path is live.
    init() {
        startAdapter()
        if adapter == nil { startHelper() }
        registerForNotifications()
        NotificationCenter.default.addObserver(
            forName: Self.nowPlayingInfoDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronous: the process exits right after this notification, so a Task may never run and
            // would orphan the perl child.
            MainActor.assumeIsolated {
                self?.adapter?.stop()
                self?.terminateHelper()
            }
        }
    }

    // No `deinit` teardown of the `NotificationCenter` observer, for the same reason
    // `SpotifyNowPlayingService` documents for its own distributed-notification observer:
    // `NotchWindowController` builds exactly one instance of this service and keeps it for the process's
    // entire lifetime. ``terminateHelper()`` is instead driven by `NSApplication.willTerminateNotification`
    // above, since a subprocess (unlike a `NotificationCenter` observer) survives its parent's death by
    // default and must be explicitly killed.

    /// Starts the perl adapter child if its files are bundled; otherwise leaves ``adapter`` `nil` so
    /// ``init()`` falls back to the xcrun helper exactly as before.
    private func startAdapter() {
        guard let paths = NowPlayingAdapterProcess.resolvePaths() else { return }
        let process = NowPlayingAdapterProcess(paths: paths)
        process.onLine = { [weak self] line in self?.handleAdapterLine(line) }
        process.onExit = { [weak self] _ in
            guard let self else { return }
            self.adapterActive = false
            self.adapterPayload = [:]
            self.adapterArtwork = nil
            self.adapterArtworkSource = nil
            // Covers both "perl never worked" and "it died mid-run": keep the old path alive meanwhile.
            if self.helperProcess == nil { self.startHelper() }
            self.refresh()
        }
        adapter = process
        process.start()
    }

    /// Applies one `{"type":"data","diff":Bool,"payload":{...}}` line from the adapter's stream. A `null`
    /// value in a diff payload means the key vanished.
    private func handleAdapterLine(_ lineData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            json["type"] as? String == "data",
            let payload = json["payload"] as? [String: Any]
        else { return }
        if !adapterActive {
            adapterActive = true
            terminateHelper()
        }
        if json["diff"] as? Bool == true {
            for (key, value) in payload {
                if value is NSNull { adapterPayload.removeValue(forKey: key) } else { adapterPayload[key] = value }
            }
        } else {
            adapterPayload = payload.filter { !($0.value is NSNull) }
        }
        let artworkString = adapterPayload["artworkData"] as? String
        if artworkString != adapterArtworkSource {
            adapterArtworkSource = artworkString
            adapterArtwork = artworkString.flatMap { Data(base64Encoded: $0) }
        }
        publishAdapterState()
    }

    /// Maps ``adapterPayload`` to ``playbackState``. Elapsed time is extrapolated from the adapter's
    /// `elapsedTimeMicros` at `timestampEpochMicros`, since the stream only emits on change, not per second.
    private func publishAdapterState() {
        let p = adapterPayload
        guard let title = p["title"] as? String, !title.isEmpty else {
            playbackState = .notRunning
            return
        }
        let isPlaying = p["playing"] as? Bool ?? false
        let rate = (p["playbackRate"] as? Double) ?? (isPlaying ? 1 : 0)
        let duration = (p["durationMicros"] as? Double ?? 0) / 1_000_000
        var position = (p["elapsedTimeMicros"] as? Double ?? 0) / 1_000_000
        if isPlaying, let stamp = p["timestampEpochMicros"] as? Double {
            position += max(0, Date().timeIntervalSince1970 - stamp / 1_000_000) * rate
        }
        if duration > 0 { position = min(position, duration) }
        playbackState = .track(
            NowPlaying(
                title: title,
                artist: p["artist"] as? String ?? "",
                artworkData: adapterArtwork,
                isPlaying: isPlaying,
                positionSeconds: position,
                durationSeconds: duration,
                sourceBundleID: p["bundleIdentifier"] as? String
            )
        )
    }

    /// Seeks the current now-playing app via the adapter (microsecond position). A no-op when the adapter is
    /// not bundled; the in-process path has no seek command.
    func seek(to seconds: Double) {
        guard let adapter, adapterActive, seconds.isFinite else { return }
        adapter.runOneShot(["seek", String(Int(max(0, seconds) * 1_000_000))])
    }

    /// Resolves the bundled helper script's on-disk path — `Contents/Resources/mediaremote-helper.swift`,
    /// copied there by `build-notch.sh` — or `nil` if it is not present (e.g. `swift run`/`swift build`
    /// outside that script's app-bundle assembly step, which never creates a `Contents/Resources` at all).
    private nonisolated static func resolveHelperScriptPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let scriptURL = resourceURL.appendingPathComponent("mediaremote-helper.swift")
        return FileManager.default.fileExists(atPath: scriptURL.path) ? scriptURL.path : nil
    }

    /// Launches `HelperScripts/mediaremote-helper.swift` as a long-lived subprocess via
    /// `/usr/bin/xcrun swift <path>` — `xcrun` resolves to the Xcode command line tools' Apple-signed `swift`
    /// interpreter, which is what lets the script read real `MediaRemote` state (see this type's own
    /// top-of-file documentation). Wires the subprocess's stdout to ``handleHelperLine(_:)`` line-by-line. A
    /// silent no-op if the script is not bundled or `/usr/bin/xcrun` is missing/fails to launch — ``refresh()``
    /// is this method's own fallback in either case.
    private func startHelper() {
        guard let scriptPath = Self.resolveHelperScriptPath() else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", scriptPath]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.helperActive = false
                self?.helperProcess = nil
            }
        }

        let lineBuffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            for lineData in lineBuffer.appendingAndSplittingLines(chunk) {
                Task { @MainActor in self.handleHelperLine(lineData) }
            }
        }

        do {
            try process.run()
            helperProcess = process
        } catch {
            // Could not launch at all (e.g. no Xcode command line tools installed) — `refresh()`'s direct
            // dlopen path below is the only option left, and per this type's own documentation, expected to
            // read back empty on this machine.
        }
    }

    /// Parses one JSON line the helper subprocess printed to stdout — see
    /// `HelperScripts/mediaremote-helper.swift`'s own documentation for the exact shape — and applies it to
    /// ``playbackState``. The first successful call here flips ``helperActive`` to `true`.
    ///
    /// - Parameter lineData: One complete line's bytes, not including the trailing newline.
    private func handleHelperLine(_ lineData: Data) {
        guard !adapterActive else { return }
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        helperActive = true
        let title = json["title"] as? String ?? ""
        guard !title.isEmpty else {
            playbackState = .notRunning
            return
        }
        let artist = json["artist"] as? String ?? ""
        let isPlaying = json["isPlaying"] as? Bool ?? false
        let elapsed = json["elapsed"] as? Double ?? 0
        let duration = json["duration"] as? Double ?? 0
        let bundleID = json["bundleID"] as? String
        let artworkData = (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        playbackState = .track(
            NowPlaying(
                title: title,
                artist: artist,
                artworkData: artworkData,
                isPlaying: isPlaying,
                positionSeconds: elapsed,
                durationSeconds: duration,
                sourceBundleID: bundleID
            )
        )
    }

    /// Kills the helper subprocess, if one is running. Called from `NSApplication.willTerminateNotification`
    /// in ``init()`` — a subprocess is not tied to its parent's lifetime the way a `NotificationCenter`
    /// observer is, so this app quitting would otherwise leave `xcrun swift mediaremote-helper.swift` running
    /// as an orphan indefinitely.
    private func terminateHelper() {
        helperProcess?.terminationHandler = nil
        helperProcess?.terminate()
        helperProcess = nil
        helperActive = false
    }

    /// Calls `MRMediaRemoteRegisterForNowPlayingNotifications` once, which is what makes `MediaRemote` start
    /// actually posting ``nowPlayingInfoDidChangeNotification`` at all — without this call, `MediaRemote`
    /// never posts it regardless of how many observers are registered on `NotificationCenter`. A no-op,
    /// silently, if the symbol could not be resolved (this service still works via ``positionTimer`` alone
    /// in that case, just without the event-driven push).
    private func registerForNotifications() {
        guard let handle = Self.handle,
            let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
        else { return }
        let register = unsafeBitCast(sym, to: RegisterForNotificationsFn.self)
        register(callbackQueue)
    }

    /// Re-reads the system's current now-playing info via `MRMediaRemoteGetNowPlayingInfo`, then (if that
    /// returned a non-empty dict) `MRMediaRemoteGetNowPlayingApplicationPID` to attribute it to a bundle
    /// identifier. Called on launch, on every change notification, and on every ``positionTimer`` tick;
    /// never polled on a timer while every panel is closed (see ``positionTimer``'s own documentation).
    ///
    /// A no-op whenever ``helperActive`` is true: this direct, in-process `dlopen` read is confirmed empty on
    /// this machine (see this type's own top-of-file documentation), so once the helper subprocess has proven
    /// it can supply real data, this fallback stands down entirely rather than periodically overwriting a
    /// real value with `.notRunning`.
    func refresh() {
        if adapterActive {
            publishAdapterState()
            return
        }
        guard !helperActive else { return }
        guard let handle = Self.handle,
            let getInfoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
        else {
            playbackState = .notRunning
            return
        }
        let getNowPlayingInfo = unsafeBitCast(getInfoSym, to: GetNowPlayingInfoFn.self)
        getNowPlayingInfo(callbackQueue) { [weak self] info in
            guard let self else { return }
            guard !info.isEmpty else {
                Task { @MainActor in self.playbackState = .notRunning }
                return
            }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            guard !title.isEmpty else {
                // A blank title is this API's own idle signal in practice (an empty dict is not the only
                // shape "nothing now playing" takes — some idle states return a sparse dict with only a
                // stale timestamp and no title at all).
                Task { @MainActor in self.playbackState = .notRunning }
                return
            }
            Self.resolveSourceBundleID(handle: handle, callbackQueue: self.callbackQueue) { bundleID in
                Task { @MainActor in
                    self.playbackState = .track(
                        NowPlaying(
                            title: title,
                            artist: artist,
                            artworkData: artworkData,
                            isPlaying: rate > 0,
                            positionSeconds: elapsed,
                            durationSeconds: duration,
                            sourceBundleID: bundleID
                        )
                    )
                }
            }
        }
    }

    /// Resolves the bundle identifier of whichever app `MediaRemote` currently attributes the now-playing
    /// entry to, via `MRMediaRemoteGetNowPlayingApplicationPID` → `NSRunningApplication`. `nonisolated`,
    /// called only from inside ``refresh()``'s own `callbackQueue` completion, never from the main actor —
    /// see ``queryNowPlaying()``-equivalent reasoning in `SpotifyNowPlayingService` for why a `static`
    /// member of an otherwise `@MainActor` type needs this annotation to actually run off-main.
    ///
    /// - Parameters:
    ///   - handle: The already-resolved `dlopen` handle.
    ///   - callbackQueue: The queue to ask `MediaRemote` to call back on.
    ///   - completion: Invoked with the resolved bundle identifier, or `nil` if the symbol could not be
    ///     resolved or the PID no longer maps to a running application.
    private nonisolated static func resolveSourceBundleID(
        handle: UnsafeMutableRawPointer,
        callbackQueue: DispatchQueue,
        completion: @escaping (String?) -> Void
    ) {
        guard let pidSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") else {
            completion(nil)
            return
        }
        let getPID = unsafeBitCast(pidSym, to: GetApplicationPIDFn.self)
        getPID(callbackQueue) { pid in
            completion(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
    }

    /// Starts (or restarts) ``positionTimer``. Called by `NotchWindowController` when any display's panel
    /// expands, exactly mirroring `SpotifyNowPlayingService.startPositionTicking()`'s own open-only contract.
    func startPositionTicking() {
        stopPositionTicking()
        // Refresh immediately on open: the change notification is not verified to fire, and the tick below
        // only re-reads while a track is already known, so media that started (or changed) while every panel
        // was closed would otherwise never appear until app relaunch. This is what makes "open the notch and
        // it shows whatever is playing right now" actually true.
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            // Refresh unconditionally while open (not only when already playing): this is how a track that
            // begins while the panel is open, or a play/pause/skip that the change notification misses, gets
            // reflected. It runs at most once a second and only while a panel is open (see the timer
            // lifecycle), so the cost is negligible and never touches idle CPU.
            self?.refresh()
        }
        positionTimer = timer
        timer.resume()
    }

    /// Cancels and forgets ``positionTimer``. Called by `NotchWindowController` when every display's panel
    /// is collapsed, mirroring `SpotifyNowPlayingService.stopPositionTicking()`.
    func stopPositionTicking() {
        positionTimer?.cancel()
        positionTimer = nil
    }

    /// Toggles play/pause on whichever app currently holds the system's now-playing entry. **Confirmed
    /// on-device** (see this type's own top-of-file documentation): `MRMediaRemoteSendCommand`, unlike the
    /// read path, is not gated by this app's ad-hoc code signature.
    func playPause() { sendCommand(.togglePlayPause) }

    /// Skips to the next track/chapter, on whichever app currently holds the now-playing entry. Same
    /// confirmed-not-gated status as ``playPause()``.
    func next() { sendCommand(.nextTrack) }

    /// Returns to the previous track/chapter. Same confirmed-not-gated status as ``playPause()``.
    func previous() { sendCommand(.previousTrack) }

    /// Sends one `MRMediaRemoteSendCommand` call and refreshes afterward, mirroring
    /// `SpotifyNowPlayingService.runTransportCommand(_:)`'s own "act, then re-read" shape. Silently a no-op
    /// if the symbol could not be resolved. Deliberately unchanged by this revision's helper-subprocess
    /// work — `MRMediaRemoteSendCommand` is confirmed not gated by code signature, so the pre-existing
    /// direct, in-process call already works; see this type's own top-of-file documentation for the probe
    /// that confirmed it (and the one caveat: the calling process's run loop must stay alive long enough for
    /// this asynchronous, XPC-backed call to actually be delivered, which `HerdNotch.app` itself always is).
    ///
    /// - Parameter command: The command to send.
    private func sendCommand(_ command: Command) {
        guard let handle = Self.handle, let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return }
        let send = unsafeBitCast(sym, to: SendCommandFn.self)
        callbackQueue.async { [weak self] in
            _ = send(command.rawValue, nil)
            Task { @MainActor in self?.refresh() }
        }
    }
}

/// A byte accumulator for ``SystemNowPlayingService/startHelper()``'s stdout `readabilityHandler`, which
/// receives arbitrary chunks (not necessarily line-aligned) of the helper subprocess's JSON-lines output.
///
/// `@unchecked Sendable`: `FileHandle.readabilityHandler` is declared to accept a plain, non-isolated
/// closure, so the Swift 6 concurrency checker treats every capture in it as needing to be `Sendable` even
/// though in practice a single `FileHandle`'s readability handler is never invoked concurrently with itself
/// (each invocation runs to completion, on GCD's own internal serial dispatch source for that file
/// descriptor, before the next can fire) — the exact same "actually serial, but not provably so to the
/// compiler" shape as `SystemNowPlayingService.handle`'s own `nonisolated(unsafe)` annotation.
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private var discarding = false
    private let maxLineBytes: Int

    /// - Parameter maxLineBytes: A longer line is dropped whole (never truncated), so a runaway stream cannot
    ///   grow the buffer without bound. `nil` keeps every line.
    init(maxLineBytes: Int? = nil) {
        self.maxLineBytes = maxLineBytes ?? .max
    }

    /// Appends `chunk` to the internal buffer, then extracts and returns every complete (newline-terminated)
    /// line now available, leaving any trailing partial line buffered for the next call.
    ///
    /// - Parameter chunk: The bytes most recently read from the helper subprocess's stdout.
    /// - Returns: Zero or more complete lines, each excluding its trailing newline, in the order they
    ///   appeared in the stream.
    func appendingAndSplittingLines(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let head = rest[..<newline]
            if discarding {
                discarding = false
            } else if buffer.count + head.count <= maxLineBytes {
                buffer.append(contentsOf: head)
                lines.append(buffer)
            }
            buffer.removeAll(keepingCapacity: true)
            rest = rest[rest.index(after: newline)...]
        }
        if !discarding {
            if buffer.count + rest.count > maxLineBytes {
                discarding = true
                buffer.removeAll(keepingCapacity: false)
            } else {
                buffer.append(contentsOf: rest)
            }
        }
        return lines
    }
}
