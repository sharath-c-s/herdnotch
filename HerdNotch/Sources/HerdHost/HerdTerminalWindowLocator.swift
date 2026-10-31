import AppKit
// For `AEDeterminePermissionToAutomateTarget`, which is what lets consent be requested outside the
// AppleScript timeout rather than inside it. See `HerdTerminalWindowLocator.permissionToAutomate`.
import CoreServices
import Foundation
import HerdKit

/// Result of attempting to raise the exact terminal window and tab attached to one herdr session.
///
/// herdr sessions are independent servers: `default` and each named session under
/// `~/.config/herdr/sessions/` each speak to their own attached terminal window, and focusing a pane
/// inside a session only moves that session's own idea of "current pane". It does nothing to macOS
/// window ordering. ``HerdTerminalWindowLocator`` closes that gap by stamping a marker into the
/// session's window title over the herdr socket, then using AppleScript to find and raise whichever
/// window now carries it. This type is the outcome of that whole attempt, one case per way it can
/// end.
enum HerdTerminalRaiseOutcome: Equatable {
    /// The marker was found on a window, and that window/tab was selected and the owning app was
    /// activated. The user is now looking at the pane they clicked.
    case raised

    /// The session is running but has no terminal attached to it, so there was never a window to raise.
    ///
    /// **This is now proven rather than inferred, and that is the correction that matters.** An earlier
    /// version returned this whenever a window search came up empty, which conflated "nothing is
    /// attached" with "something is attached but I could not find its window". They call for different
    /// responses: the first is a fact to show the user, the second is a reason to fall back. herdr answers
    /// the question directly, because `client.window_title.set` cannot set a title without a foreground
    /// client and says so, reporting `no_foreground_client`. One round trip, authoritative.
    ///
    /// It is also returned when the terminal application is not running at all, since scripting it would
    /// launch a fresh unattached instance rather than reveal an existing window, and launching a terminal
    /// on the user's behalf is not this feature's job.
    case notAttached

    /// A client is attached, but no window carrying the marker was found across every polling attempt.
    ///
    /// Separate from ``notAttached`` because the caller should still fall back to activating the terminal
    /// application: there genuinely is a window somewhere, and raising the app is at least never wrong
    /// about *which app*, only sometimes wrong about *which window*.
    case windowNotFound

    /// AppleScript itself could not be used: it errored, timed out, or Automation permission was
    /// denied. The associated string is a short, readable explanation (already decoded from the
    /// AppleScript error number) suitable for a log line or, in future, a UI toast.
    ///
    /// This is distinct from ``notAttached`` because it means the search was never actually
    /// completed, so nothing is known about whether a matching window exists.
    case scriptingUnavailable(String)

    /// The terminal's bundle identifier is not one this locator knows how to script. The associated
    /// string is the bundle identifier itself, so a caller or future UI can name the culprit.
    case unsupportedTerminal(String)
}

extension HerdTerminalRaiseOutcome: CustomStringConvertible {
    /// A short, log-friendly rendering, e.g. `raised`, `notAttached`,
    /// `scriptingUnavailable(AppleScript timed out (-1712): ...)`.
    var description: String {
        switch self {
        case .raised: return "raised"
        case .notAttached: return "notAttached"
        case .windowNotFound: return "windowNotFound"
        case .scriptingUnavailable(let message): return "scriptingUnavailable(\(message))"
        case .unsupportedTerminal(let bundleId): return "unsupportedTerminal(\(bundleId))"
        }
    }
}

/// Raises the specific terminal window and tab that is currently attached to one herdr session, by
/// round-tripping a marker through the session's own window title.
///
/// The problem this solves: raising a terminal application by bundle identifier (what
/// `NSRunningApplication.activate()` does) brings forward whichever window last had keyboard focus,
/// which is correct only when the user has one herdr session open. With several sessions, each in its
/// own window, activating the app is a coin flip: the visible window is very often the wrong one, and
/// there is no way to tell from the outside which macOS window belongs to which herdr session, because
/// herdr's own `terminal_id` (e.g. `term_657068fc62f8c2`) identifies a herdr-side record, not anything
/// the window server knows about.
///
/// The fix is to make the terminal say which session it is, using a channel herdr already has: window
/// titles. `client.window_title.set` on a session's socket sets the title of whichever real terminal
/// frontend is attached to that session, which is exactly the visible window we need to find. This
/// type stamps a short, human-readable marker (`herdr:<sessionName>`), polls for a window whose title
/// carries it, raises that window if found, and always restores the user's own title afterwards, so a
/// failed raise never leaves a mangled title behind.
///
/// Scripting is inherently unreliable in a sandboxed, Automation-gated environment: a target app may
/// be slow to respond, the user may not have granted Automation permission, or a probe may simply time
/// out. Every AppleScript execution here is wrapped in `with timeout of 2 seconds` and every failure
/// path is mapped to ``HerdTerminalRaiseOutcome/scriptingUnavailable(_:)`` rather than left to throw or
/// hang, because a menu-bar click must never wedge waiting on a permission dialog or a stuck script.
///
/// Thread-safety: holds no mutable state, so one instance can be reused freely, but every call is
/// synchronous and blocking (herdr socket round trips plus up to five AppleScript executions, each
/// bounded at 2 seconds). Callers must run it off the main actor, matching how ``HerdFocusService``
/// already runs its own herdr calls on a background queue.
struct HerdTerminalWindowLocator {
    /// Terminal applications this locator knows how to script, and the AppleScript dialect each one
    /// needs.
    ///
    /// iTerm2 and Terminal.app model "window containing tabs" differently enough (iTerm2 additionally
    /// nests `sessions` inside a tab; Terminal.app's tabs are the leaf) that a single script template
    /// cannot serve both. Any other bundle identifier is simply unsupported: scripting a terminal
    /// blind, without knowing its object model, would be as likely to corrupt state as to help.
    private enum SupportedTerminal {
        case iTerm2
        case terminalApp

        /// Resolves a bundle identifier to the terminal family it belongs to.
        ///
        /// - Parameter bundleId: A running application's bundle identifier.
        /// - Returns: `nil` when the identifier is not one of the two terminals this locator scripts.
        init?(bundleId: String) {
            switch bundleId {
            case "com.googlecode.iterm2": self = .iTerm2
            case "com.apple.Terminal": self = .terminalApp
            default: return nil
            }
        }

        /// Builds the AppleScript source that searches for a window whose title satisfies `condition` and,
        /// if found, selects it (and its tab) and activates the application.
        ///
        /// The search and the raise are one script, not two, because splitting them would mean a
        /// second round trip through `NSAppleScript` (and a second Automation permission check) for
        /// what is logically a single "find and show" operation. The script returns the literal string
        /// `"found"` or `"notfound"` so the Swift side can tell a genuine miss (keep polling) apart
        /// from every other outcome (an `NSDictionary` error from `executeAndReturnError`).
        ///
        /// The title is read into the local `n` first and `condition` is written against that variable,
        /// so the whole match rule is one expression built once in Swift from
        /// ``HerdrClient/windowTitle(_:isFor:)``'s own inputs rather than being spelled out twice here.
        ///
        /// For iTerm2 the useful step is `tell w to select t`, not `select w`. The user's herdr sessions
        /// are tabs inside a single iTerm2 window (`count of windows` is 1 on the machine this was
        /// debugged on), so `select w` is very nearly a no-op and the tab selection is doing all the
        /// work. Both are kept because the multi-window case is equally real, and `activate` comes last
        /// so that bringing the application forward cannot land focus on the tab that was current
        /// before the selection.
        ///
        /// - Parameter condition: An AppleScript boolean expression over the variable `n`, holding the
        ///   title under test. Callers build it with
        ///   ``HerdTerminalWindowLocator/titleCondition(variable:sessionName:)``, which escapes its own
        ///   literals; this method does no escaping.
        /// - Returns: Complete AppleScript source, wrapped in a 2 second timeout.
        func script(condition: String) -> String {
            switch self {
            case .iTerm2:
                return """
                with timeout of 2 seconds
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    set n to name of s
                                    if \(condition) then
                                        select w
                                        tell w to select t
                                        activate
                                        return "found"
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "notfound"
                    end tell
                end timeout
                """
            case .terminalApp:
                return """
                with timeout of 2 seconds
                    tell application "Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                set n to name of t
                                if \(condition) then
                                    set index of w to 1
                                    set selected tab of w to t
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                        return "notfound"
                    end tell
                end timeout
                """
            }
        }
    }

    /// Result of one polling loop: either the window was found, the attempts were exhausted without
    /// finding it, or scripting itself failed and further attempts would not help.
    private enum PollOutcome {
        case found
        case notFound
        case scriptingUnavailable(String)
    }

    /// Maximum number of times the marker window is searched for before giving up.
    ///
    /// Terminal title updates delivered over the herdr socket are asynchronous with respect to the
    /// AppleScript poll, so the first attempt, sometimes the second, will typically miss even when the
    /// terminal is about to update. Five attempts at ``pollInterval`` spacing keeps the worst case
    /// (all misses) under one second while giving the title update time to land.
    private static let maxAttempts = 5

    /// Spacing between polling attempts.
    private static let pollInterval: TimeInterval = 0.15

    /// Creates a locator. Stateless, so this can be called freely, including once per raise attempt.
    init() {}

    /// Raises the terminal window attached to one herdr session, identified by stamping and searching
    /// for a marker title.
    ///
    /// Sequence:
    /// 1. Stamp `herdr: <sessionName>` via `client.window_title.set` on the session's socket, whose reply
    ///    doubles as the attachment probe.
    /// 2. Obtain Automation consent for the terminal, blocking on the user if this is the first time. Done
    ///    before any timed script runs, because a consent dialog cannot be answered inside a two second
    ///    AppleScript timeout and the abandoned prompt is recorded as a permanent denial.
    /// 3. Poll for a window whose title matches that session exactly, via AppleScript, up to
    ///    ``maxAttempts`` times.
    /// 4. If found, the polling script itself already selected the window and its tab and activated the
    ///    app.
    ///
    /// The title is deliberately never cleared; see the comment in the body for why.
    ///
    /// - Parameters:
    ///   - sessionName: The herdr session name (e.g. `default`, `oncall_20-23_07`), used verbatim as
    ///     the marker's suffix. Chosen over a random token deliberately: if the raise fails, the user
    ///     is left looking at *some* window with title `herdr:<sessionName>`, which at least tells them
    ///     which session that window is in, rather than a meaningless opaque string.
    ///   - socketPath: Absolute path of the session's `herdr.sock`, used to build a fresh
    ///     ``HerdrClient``.
    ///   - bundleId: Bundle identifier of the terminal application to search. Only iTerm2
    ///     (`com.googlecode.iterm2`) and Terminal.app (`com.apple.Terminal`) are supported; any other
    ///     value returns ``HerdTerminalRaiseOutcome/unsupportedTerminal(_:)`` without touching herdr or
    ///     AppleScript at all.
    /// - Returns: The outcome of the attempt. See ``HerdTerminalRaiseOutcome`` for what each case
    ///   means and when it is chosen.
    /// - Throws: Whatever ``HerdrClient/call(_:params:timeout:)`` throws for the initial
    ///   `client.window_title.set`. This is the one step that cannot be answered from inside
    ///   ``HerdTerminalRaiseOutcome``, since it means the session itself could not be reached (for
    ///   example it stopped between the caller's own herdr calls succeeding and this one running), not
    ///   that the terminal or its scripting was at fault. Callers are expected to catch this and fall
    ///   back to activating the terminal application the old way, exactly as they would for any other
    ///   herdr call failure.
    func raise(sessionName: String, socketPath: String, bundleId: String) throws -> HerdTerminalRaiseOutcome {
        guard let terminal = SupportedTerminal(bundleId: bundleId) else {
            return .unsupportedTerminal(bundleId)
        }

        // Scripting an application that is not running would launch a brand-new, unattached instance
        // of it rather than reveal an existing window. That is never the right outcome here: there is
        // nothing to raise, so this is reported the same way as "no window carries the marker".
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
            return .notAttached
        }

        let marker = HerdrClient.windowTitle(for: sessionName)
        let client = HerdrClient(socketPath: socketPath)

        // One call does two jobs: it stamps the discriminator the window search needs, and its response is
        // the attachment probe. If nothing is attached there is no window to look for, so this returns
        // before spending a second on AppleScript.
        let probe = try client.setWindowTitle(marker)
        guard !probe.isDetached else { return .notAttached }

        // The title is deliberately NOT cleared. Before stamping, every attached herdr window was titled
        // `herdr (herdr)`, so two attached sessions were indistinguishable both to the user reading their
        // window list and to any code trying to find one of them. `herdr: <session>` fixes both with the
        // same string. Clearing it would also reintroduce a race this design exists to avoid: terminals
        // apply titles asynchronously, which is the only reason the search below has to poll at all, and a
        // persistently stamped title means the window is already findable on the next raise.

        // Asked for explicitly, before the first Apple event, and this is the whole of the fix for the
        // reported bug. See ``permissionToAutomate(bundleId:)``.
        let permission = Self.permissionToAutomate(bundleId: bundleId)
        guard permission == noErr else {
            return .scriptingUnavailable(Self.message(forPermissionStatus: permission, bundleId: bundleId))
        }

        let script = terminal.script(condition: Self.titleCondition(variable: "n", sessionName: sessionName))
        switch pollUntilFound(scriptSource: script) {
        case .found: return .raised
        case .notFound: return .windowNotFound
        case .scriptingUnavailable(let message): return .scriptingUnavailable(message)
        }
    }

    /// Selects the iTerm2 session or Terminal.app tab whose `tty` is `tty`, and activates the app.
    ///
    /// The tty is a stable identifier, so a miss is final and the script runs once rather than polling.
    /// Same Automation-permission and not-running rules as ``raise(sessionName:socketPath:bundleId:)``.
    /// Blocking: call off the main actor.
    ///
    /// - Parameters:
    ///   - tty: Bare device name such as `ttys004`.
    ///   - bundleId: iTerm2 or Terminal.app.
    func raise(tty: String, bundleId: String) -> HerdTerminalRaiseOutcome {
        guard let terminal = SupportedTerminal(bundleId: bundleId) else { return .unsupportedTerminal(bundleId) }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
            return .notAttached
        }
        let permission = Self.permissionToAutomate(bundleId: bundleId)
        guard permission == noErr else {
            return .scriptingUnavailable(Self.message(forPermissionStatus: permission, bundleId: bundleId))
        }
        let script = TerminalTTYScript.script(iTerm2: terminal == .iTerm2, tty: tty)
        switch pollUntilFound(scriptSource: script, attempts: 1) {
        case .found: return .raised
        case .notFound: return .windowNotFound
        case .scriptingUnavailable(let message): return .scriptingUnavailable(message)
        }
    }

    /// Repeatedly executes `scriptSource` until it reports the marker was found, attempts are
    /// exhausted, or AppleScript itself fails.
    ///
    /// A scripting failure (permission denial, timeout, any other AppleScript error) stops the loop
    /// immediately rather than retrying up to ``maxAttempts`` times: if AppleScript cannot talk to the
    /// terminal at all, spending the rest of the attempt budget retrying the same broken call would
    /// only spend time without changing the answer.
    ///
    /// - Parameter scriptSource: Complete AppleScript source, as built by
    ///   ``SupportedTerminal/script(markerLiteral:)``.
    /// - Returns: ``PollOutcome/found`` as soon as one execution reports the marker,
    ///   ``PollOutcome/notFound`` once every attempt has reported a miss,
    ///   ``PollOutcome/scriptingUnavailable(_:)`` as soon as one execution errors.
    private func pollUntilFound(scriptSource: String, attempts: Int = HerdTerminalWindowLocator.maxAttempts) -> PollOutcome {
        for attempt in 0..<attempts {
            let (found, scriptError) = executeOnce(scriptSource)
            if let scriptError {
                return .scriptingUnavailable(scriptError)
            }
            if found {
                return .found
            }
            if attempt < attempts - 1 {
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }
        return .notFound
    }

    /// Executes one AppleScript source string with a fresh `NSAppleScript` instance.
    ///
    /// A fresh instance per call, never a shared one, because `NSAppleScript` is documented as not
    /// thread-safe and this locator makes no promise about which thread it runs on beyond "not the
    /// main actor".
    ///
    /// - Parameter source: Complete AppleScript source to run.
    /// - Returns: `found: true` when the script's result was the literal string `"found"`; otherwise
    ///   `found: false`. `error` carries a decoded, readable message when execution failed (see
    ///   ``message(for:)``), and is `nil` on a clean `"found"`/`"notfound"` result.
    private func executeOnce(_ source: String) -> (found: Bool, error: String?) {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let descriptor = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return (false, Self.message(for: errorInfo))
        }
        return (descriptor?.stringValue == "found", nil)
    }

    /// Decodes an `NSAppleScript` error dictionary into a short, readable message, calling out the two
    /// error numbers this feature is expected to hit routinely.
    ///
    /// - Parameter errorInfo: The `NSDictionary` populated by
    ///   `NSAppleScript.executeAndReturnError(_:)` on failure.
    /// - Returns: A message naming the error number and herdr's own description of it. `-1743`
    ///   ("not authorized") means the user has not granted this app Automation permission for the
    ///   target terminal; `-1712` means the `with timeout of 2 seconds` wrapper fired because the
    ///   terminal did not respond in time. Both, and every other error number, are reported the same
    ///   way to the caller (as ``HerdTerminalRaiseOutcome/scriptingUnavailable(_:)``); the distinction
    ///   is only for the message text a human reads in the log.
    private static func message(for errorInfo: NSDictionary) -> String {
        let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        let text = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        switch number {
        case -1743: return "Automation permission denied (-1743): \(text)"
        case -1712: return "AppleScript timed out (-1712): \(text)"
        default: return "AppleScript error \(number): \(text)"
        }
    }

    /// Asks the system whether this process may send Apple events to `bundleId`, prompting the user the
    /// first time and blocking until they answer.
    ///
    /// **This call is the fix for the reported bug, and the bug had two layers.** Clicking a row in a
    /// session the terminal was not showing did nothing, permanently and silently, and neither layer
    /// produced anything a user could see.
    ///
    /// The first layer was the signature. `build.sh` signs with `--options runtime`, and under the
    /// hardened runtime a process may not send Apple events at all unless it carries
    /// `com.apple.security.automation.apple-events`. That check happens inside the sending process before
    /// TCC is ever consulted, so `NSAppleScript` returned `-1743` on the very first execution, no consent
    /// prompt appeared, the app never showed up in System Settings under Automation, and `tccd` logged
    /// nothing at all. `NSAppleEventsUsageDescription` in the Info.plist did not help, because that string
    /// is only the text of a prompt that was never going to be shown. The entitlement is now signed in.
    ///
    /// The second layer is why this method exists rather than just the entitlement. With the entitlement
    /// present the first send does reach TCC and does raise the consent dialog, but the script is wrapped
    /// in `with timeout of 2 seconds`, and no human answers a dialog in two seconds. The wrapper fired,
    /// AppleScript returned `-1712`, and the abandoned prompt was recorded by TCC as a **denial**, after
    /// which every later attempt failed with `-1743` and no prompt, forever. That is exactly the `-1712`
    /// seen earlier and mistaken for an artefact of a test harness; it was real, and it was a permanent
    /// self-inflicted denial. Asking here, through `AEDeterminePermissionToAutomateTarget`, moves consent
    /// outside the AppleScript timeout: this call blocks for as long as the user needs, and only once the
    /// answer is known does any timed script run.
    ///
    /// Called only after the attachment probe has proved a terminal is attached, so clicking a row in a
    /// detached session such as `oncall_20-23_07` still returns
    /// ``HerdTerminalRaiseOutcome/notAttached`` without ever asking the user for Automation permission.
    ///
    /// Must not be called on the main actor: it blocks until the user dismisses the dialog.
    ///
    /// - Parameter bundleId: Bundle identifier of the terminal this process wants to script.
    /// - Returns: `noErr` when events may be sent. `errAEEventNotPermitted` (-1743) when permission is
    ///   refused, which after a refusal is returned immediately and without a prompt. `procNotFound`
    ///   (-600) when nothing with that identifier is running. Any other `OSStatus` comes from
    ///   `AECreateDesc` failing to build the target descriptor.
    private static func permissionToAutomate(bundleId: String) -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Array(bundleId.utf8)
        let created = AECreateDesc(
            typeApplicationBundleID, identifier, identifier.count, &target
        )
        // Widened rather than compared as-is: `AECreateDesc` answers in `OSErr`, which is 16 bit, while
        // every other status in this file is a 32 bit `OSStatus`.
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        // `typeWildCard` for both class and id: the permission TCC grants is per target application, not
        // per event, so there is nothing gained by naming the specific events the script will send, and
        // naming them would have to be kept in step with two AppleScript dialects.
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, true
        )
    }

    /// Turns a permission status into a message that says what the user can do about it.
    ///
    /// - Parameters:
    ///   - status: The `OSStatus` from ``permissionToAutomate(bundleId:)``.
    ///   - bundleId: The terminal that was being asked for, named in the message so the log line and any
    ///     future toast identify the row in System Settings the user has to change.
    /// - Returns: A short readable explanation.
    private static func message(forPermissionStatus status: OSStatus, bundleId: String) -> String {
        switch status {
        case OSStatus(errAEEventNotPermitted):
            return "Automation permission denied (-1743): allow this app to control \(bundleId) under "
                + "System Settings > Privacy & Security > Automation, then click the row again."
        case OSStatus(procNotFound):
            return "\(bundleId) is not running (-600), so there is no window to raise."
        default:
            return "Automation permission could not be determined (\(status)) for \(bundleId)."
        }
    }

    /// Builds the AppleScript boolean expression that recognises one session's stamped window title.
    ///
    /// The rule itself lives in ``HerdrClient/windowTitle(_:isFor:)`` and is unit tested there; this only
    /// renders the same inputs as AppleScript source, so the exact-match behaviour cannot be true in Swift
    /// and quietly different in the script.
    ///
    /// - Parameters:
    ///   - variable: Name of the AppleScript variable holding the title under test.
    ///   - sessionName: The herdr session being looked for.
    /// - Returns: An expression such as
    ///   `n is "herdr: default" or n starts with "herdr: default ("`, with every literal escaped.
    private static func titleCondition(variable: String, sessionName: String) -> String {
        // Session names are directory names, escaped defensively rather than trusted.
        let marker = HerdrClient.windowTitle(for: sessionName)
        var clauses = ["\(variable) is \"\(TerminalTTYScript.escapedLiteral(marker))\""]
        clauses += HerdrClient.windowTitlePrefixes(for: sessionName).map {
            "\(variable) starts with \"\(TerminalTTYScript.escapedLiteral($0))\""
        }
        return clauses.joined(separator: " or ")
    }
}
