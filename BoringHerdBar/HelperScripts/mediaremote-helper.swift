// mediaremote-helper.swift
//
// WHY THIS FILE MUST STAY A LOOSE `.swift` SOURCE FILE, NEVER COMPILED BY US:
//
// On macOS 26.2, `MRMediaRemoteGetNowPlayingInfo` (and friends, in the private
// `/System/Library/PrivateFrameworks/MediaRemote.framework`) returns an EMPTY dictionary to a caller that is
// not Apple-signed. `HerdNotch.app` is ad-hoc-signed (see `build-notch.sh`'s own `codesign --sign -`), so its
// own in-process `dlopen`/`dlsym` calls in `SystemNowPlayingService.swift` always see nothing on this
// machine — confirmed empirically: a compiled-and-ad-hoc-signed probe binary running the exact same
// `MRMediaRemoteGetNowPlayingInfo` call this file makes returned `keys=0`, while running that identical code
// as THIS file, interpreted (not compiled) via `xcrun swift mediaremote-helper.swift`, returned an 18-key
// dictionary (title, artist, elapsed time, artwork bytes, and more) for whatever was actually playing.
// `xcrun`/`swift` themselves are Apple-signed, and macOS's private-framework gate keys off the caller's own
// signature, not the source file's — so running this exact source THROUGH the Apple-signed interpreter is
// what dodges the gate. Compiling this file into a `.o`/binary and ad-hoc-signing that binary (the same thing
// `build-notch.sh` does to the rest of HerdNotch) would reproduce the empty-dict problem this file exists to
// route around. This is the same reason BoringNotch ships an external Apple-signed `mediaremote-adapter`
// helper rather than reading `MediaRemote` from its own app process.
//
// `MRMediaRemoteSendCommand` (play/pause/next/previous) is a SEPARATE finding: empirically, on this machine,
// it is NOT gated by the caller's code signature — an ad-hoc-signed compiled binary calling
// `MRMediaRemoteSendCommand` toggled Spotify's actual playback state exactly as reliably as the same call
// made through this Apple-signed interpreter path, provided the calling process's run loop stayed alive long
// enough for the (asynchronous, XPC-backed) command to actually be delivered before the process exited — a
// non-issue for `HerdNotch.app` itself, which is a long-lived GUI app with its own run loop always pumping.
// That is why `SystemNowPlayingService.sendCommand(_:)` still calls `MRMediaRemoteSendCommand` directly,
// in-process, unchanged — this helper is a READ-ONLY now-playing source, not a transport.
//
// WHAT THIS SCRIPT DOES:
// `dlopen`s MediaRemote, registers for `kMRMediaRemoteNowPlayingInfoDidChangeNotification`, and on every
// change (plus one read immediately at launch, plus a roughly-1-second heartbeat as a hedge against the
// change notification ever failing to fire — the exact same hedge `SystemNowPlayingService.positionTimer`
// already carries for its own now-superseded direct read path) prints exactly ONE line of JSON to stdout:
// `{"title": String, "artist": String, "isPlaying": Bool, "elapsed": Double, "duration": Double,
// "bundleID": String?, "hasArtwork": Bool, "artwork": String? (base64, present only when small enough to be
// worth carrying)}`. `SystemNowPlayingService` launches this script as a long-lived subprocess (via
// `/usr/bin/xcrun swift`) and parses each line as it arrives; see that file's own documentation for the
// subprocess-management and fallback side of this contract.
//
// This process never writes anything but complete JSON lines to stdout, and never reads stdin at all —
// transport commands are not this file's job (see above), so there is nothing for it to listen for.

import AppKit
import Foundation

/// The private framework's on-disk path — see `SystemNowPlayingService.frameworkPath`'s own documentation for
/// why `dlopen` still resolves this correctly even though the path does not exist as a standalone file.
let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

guard let mediaRemoteHandle = dlopen(frameworkPath, RTLD_NOW) else {
    FileHandle.standardError.write(Data("mediaremote-helper: dlopen failed\n".utf8))
    exit(1)
}

typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
typealias GetApplicationPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
typealias RegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void

/// Resolves one symbol from the already-open `MediaRemote` handle, or `nil` if this OS release moved or
/// removed it — this script degrades to silence (no output at all) rather than crashing in that case, and
/// `SystemNowPlayingService` treats "the helper streamed nothing" as its own cue to fall back.
func resolvedSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(mediaRemoteHandle, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

guard let getNowPlayingInfo = resolvedSymbol("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFn.self)
else {
    FileHandle.standardError.write(Data("mediaremote-helper: MRMediaRemoteGetNowPlayingInfo missing\n".utf8))
    exit(1)
}
let getApplicationPID = resolvedSymbol("MRMediaRemoteGetNowPlayingApplicationPID", as: GetApplicationPIDFn.self)

/// The queue every `MediaRemote` completion handler below is asked to call back on — never `.main`, so a
/// slow completion can never block the heartbeat timer or the notification observer, both of which run on
/// `.main` (mirroring `SystemNowPlayingService.callbackQueue`'s own off-main reasoning).
let callbackQueue = DispatchQueue(label: "mediaremote-helper.callback")

/// Serializes writes to stdout: the heartbeat timer, the change-notification observer, and the initial read
/// each run their own async `MediaRemote` completion, so two lines could in principle be ready to write at
/// once. A single line is always written atomically (one `FileHandle.write` call), so this exists only to
/// keep two *different* lines from ever interleaving mid-write.
let stdoutLock = NSLock()

/// Writes one JSON object as a single newline-terminated line to stdout. Uses `FileHandle.write` rather than
/// `print`, deliberately: stdout is a pipe to `SystemNowPlayingService`'s `Process`, not a tty, and Swift's
/// libc-backed `print` fully block-buffers a non-tty stdout — `SystemNowPlayingService` would then see
/// nothing until the buffer happened to fill, defeating the entire point of a live stream. `FileHandle.write`
/// goes straight to the `write(2)` syscall with no such buffering.
func emitLine(_ json: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
    data.append(0x0A)
    stdoutLock.lock()
    FileHandle.standardOutput.write(data)
    stdoutLock.unlock()
}

/// Re-reads `MediaRemote`'s current now-playing info and emits one JSON line describing it. Called at launch,
/// on every `kMRMediaRemoteNowPlayingInfoDidChangeNotification`, and on every heartbeat tick.
func emitNowPlaying() {
    getNowPlayingInfo(callbackQueue) { info in
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

        func finish(bundleID: String?) {
            var payload: [String: Any] = [
                "title": title,
                "artist": artist,
                "isPlaying": rate > 0,
                "elapsed": elapsed,
                "duration": duration,
                "hasArtwork": artworkData != nil,
            ]
            payload["bundleID"] = bundleID as Any? ?? NSNull()
            // Omit artwork entirely above roughly 200KB base64-encoded rather than truncate it: a partial
            // image is worse than none, and `SystemNowPlayingService`'s own documentation already treats a
            // missing artwork as a normal, expected shape (the browser-tab case its original probe hit).
            if let artworkData, artworkData.count < 150_000 {
                payload["artwork"] = artworkData.base64EncodedString()
            }
            emitLine(payload)
        }

        guard let getApplicationPID else {
            finish(bundleID: nil)
            return
        }
        getApplicationPID(callbackQueue) { pid in
            let bundleID = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
            finish(bundleID: bundleID)
        }
    }
}

if let register = resolvedSymbol(
    "MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterForNotificationsFn.self
) {
    register(callbackQueue)
}
NotificationCenter.default.addObserver(
    forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
    object: nil,
    queue: nil
) { _ in emitNowPlaying() }

// The initial read: without this, `SystemNowPlayingService` would see nothing until the first change
// notification (which, per its own documentation, was never confirmed to reliably fire at all).
emitNowPlaying()

// The heartbeat: a hedge against the change notification never firing in practice, exactly mirroring
// `SystemNowPlayingService.positionTimer`'s own reasoning for its now-superseded direct-read tick.
let heartbeat = DispatchSource.makeTimerSource(queue: .main)
heartbeat.schedule(deadline: .now() + 1, repeating: 1)
heartbeat.setEventHandler { emitNowPlaying() }
heartbeat.resume()

RunLoop.main.run()
