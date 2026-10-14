import Combine
import CoreGraphics
import Foundation
import HerdHotKey
import HerdKit
import HerdPanelUI
import HerdShortcut

/// Every configurable value in the app, read from and written to `UserDefaults`.
///
/// Plain `UserDefaults` rather than the `Defaults` package: a dozen keys do not justify a dependency, and
/// this app has no Xcode project in which to resolve one conveniently.
///
/// It is an `ObservableObject`, and that is what makes the settings window work with no plumbing of its
/// own. Every setter announces the change, so the form's bindings write straight through to defaults and
/// the app delegate can act on the one or two settings that need more than a stored value (re-registering
/// the global shortcut, refreshing the status item, re-polling after the remote paths change). One source
/// of truth, one notification, no mirrored state to keep in sync.
///
/// The key names are shared verbatim with the parked boringNotch fork, so a user who ever runs both
/// surfaces gets one set of behaviour rather than two that drift. Renaming a key here silently
/// desynchronises the two apps.
///
/// Public, and moved out of `BoringHerdBar` into this library, because both host apps now read and write
/// the same `UserDefaults` keys through the same class: `BoringHerdBar/AppDelegate` builds one instance
/// and so does `HerdNotch/NotchAppDelegate`, and this is what makes "no earlier setting is lost" true for
/// the notch app rather than merely aspirational.
///
/// Thread-safety: main-actor isolated. `UserDefaults` itself is thread-safe, but every reader here is
/// UI code and the isolation keeps the compiler from having to be convinced of that.
@MainActor
public final class HerdPreferences: ObservableObject {
    /// Defaults keys, kept in one place so the fork can be diffed against this list.
    ///
    /// The two shortcut keys are not here: they belong to ``HerdShortcutStore``, which owns the encoding
    /// rule for them, and duplicating the names would be two places to rename.
    private enum Key {
        /// Whether to poll at all. Off means the status item shows a paused marker and no I/O happens.
        static let enabled = "herdEnabled"
        /// Seconds between polls while the panel is open.
        static let pollInterval = "herdPollInterval"
        /// Whether to post a notification when an agent becomes blocked.
        static let notifyOnBlocked = "herdNotifyOnBlocked"
        /// Session names to show. Empty means all.
        static let sessionFilter = "herdSessionFilter"
        /// Bundle identifier of the terminal hosting herdr. Empty means auto-detect.
        static let terminalBundleId = "herdTerminalBundleId"
        /// Whether to show the transient menu bar popup on notable transitions.
        static let popupEnabled = "herdPopupEnabled"
        /// Seconds the transient popup stays on screen.
        static let popupDuration = "herdPopupDuration"
        /// Point size of the ledger's agent identifier, from which every other panel size is derived.
        static let ledgerTextSize = "herdLedgerTextSize"
        /// Whether to stamp `herdr: <session>` on each attached terminal window.
        static let stampWindowTitles = "herdStampWindowTitles"
        /// Whether to scan ``remotePaths`` in addition to `~/.config/herdr`.
        static let remoteEnabled = "herdRemoteEnabled"
        /// Extra socket paths or directories holding forwarded remote sessions.
        static let remotePaths = "herdRemotePaths"
        /// Which agent sources feed the panel: `herdr`, `local` or `both`.
        static let agentSourceMode = "herdAgentSourceMode"
        /// Whether clicking a local agent tries to bring its terminal or IDE forward.
        static let jumpToAgent = "herdJumpToAgent"
        /// Minutes a task must run before its finish is announced. 0 announces every finish as before.
        static let longTaskMinutes = "herdLongTaskMinutes"
    }

    /// Popup durations offered in the settings window, in seconds.
    ///
    /// The range is clamped to these bounds on read as well, so a hand-edited plist cannot produce a
    /// popup that flashes past unread or one that never goes away.
    public static let selectablePopupDurations: [TimeInterval] = [2, 4, 8, 15]

    /// Poll intervals offered in the settings window, in seconds.
    ///
    /// A measured `agent.list` round trip is about 36 ms, so even the fastest option spends well under
    /// 20 % of a second on I/O across four sessions. The slow options exist for people who want the
    /// panel to cost nothing rather than for people who need less latency.
    public static let selectablePollIntervals: [TimeInterval] = [0.5, 1.0, 2.0, 5.0]

    /// The backing store. Injectable so a test can hand in a scratch suite.
    private let defaults: UserDefaults

    /// Creates a preferences accessor and registers the shipped defaults.
    ///
    /// Registration rather than `??` at each read site: it means `objectIsForced` and `defaults read`
    /// from the shell both show the effective value, and there is exactly one place that states what
    /// the shipped default is.
    ///
    /// - Parameter defaults: Backing store. Defaults to `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var shipped: [String: Any] = [
            Key.enabled: true,
            Key.pollInterval: 1.0,
            Key.notifyOnBlocked: true,
            Key.sessionFilter: [String](),
            Key.terminalBundleId: "",
            Key.popupEnabled: true,
            Key.popupDuration: 4.0,
            Key.ledgerTextSize: HerdLedgerScale.defaultIdentifierSize,
            Key.stampWindowTitles: true,
            // Off by default: scanning paths nobody configured would be a no-op, and a feature that is
            // silently on is a feature nobody can reason about when it misbehaves.
            Key.remoteEnabled: false,
            Key.remotePaths: [String](),
            Key.agentSourceMode: AgentSourceMode.both.rawValue,
            Key.jumpToAgent: true,
            Key.longTaskMinutes: 5
        ]
        shipped.merge(HerdShortcutStore.registrationDefaults) { current, _ in current }
        defaults.register(defaults: shipped)
    }

    // MARK: - Global shortcut

    /// The system-wide shortcut that opens pane search.
    ///
    /// Writable, and settable from the settings window, which is the change that made this app's one
    /// keyboard affordance genuinely configurable rather than documented-as-a-`defaults write`. The
    /// encoding lives in ``HerdShortcutStore``; the only thing worth repeating here is that writing it
    /// does not register it. The app delegate observes this object and re-registers, so a rebind takes
    /// effect without a relaunch, and a rebind Carbon refuses is reported through ``HerdHotKeyStatus``
    /// rather than swallowed.
    ///
    /// The two defaults keys remain writable by hand for anyone who prefers that:
    ///
    /// ```
    /// defaults write com.boringherd.BoringHerdBar herdSearchHotKeyCode -int 4
    /// defaults write com.boringherd.BoringHerdBar herdSearchHotKeyModifiers -int 2304
    /// ```
    public var searchShortcut: HerdShortcut {
        get { HerdShortcutStore.read(from: defaults) }
        set {
            objectWillChange.send()
            HerdShortcutStore.write(newValue, to: defaults)
        }
    }

    /// Forgets a custom shortcut, restoring the shipped `fn fn` default.
    public func resetSearchShortcut() {
        objectWillChange.send()
        HerdShortcutStore.reset(in: defaults)
    }

    // MARK: - Watching

    /// Whether polling is active. When false the model stops all herdr I/O.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { set(newValue, forKey: Key.enabled) }
    }

    /// Seconds between polls while the panel is open.
    ///
    /// Clamped to the selectable range on read so a hand-edited plist cannot produce a zero interval
    /// and spin the poll loop.
    public var pollInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.pollInterval)
            guard let lowest = Self.selectablePollIntervals.first,
                  let highest = Self.selectablePollIntervals.last else { return 1.0 }
            return min(max(stored, lowest), highest)
        }
        set { set(newValue, forKey: Key.pollInterval) }
    }

    // MARK: - Alerts

    /// Whether to post a notification on an agent becoming blocked.
    public var notifiesOnBlocked: Bool {
        get { defaults.bool(forKey: Key.notifyOnBlocked) }
        set { set(newValue, forKey: Key.notifyOnBlocked) }
    }

    /// Whether the transient menu bar popup appears on notable transitions.
    ///
    /// Separate from ``notifiesOnBlocked`` so the quiet on-screen hint and the system notification can
    /// be turned off independently: several people want one and not the other.
    public var showsPopup: Bool {
        get { defaults.bool(forKey: Key.popupEnabled) }
        set { set(newValue, forKey: Key.popupEnabled) }
    }

    /// Seconds the transient popup stays on screen, clamped to the selectable range.
    public var popupDuration: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.popupDuration)
            guard let lowest = Self.selectablePopupDurations.first,
                  let highest = Self.selectablePopupDurations.last else { return 4.0 }
            return min(max(stored, lowest), highest)
        }
        set { set(newValue, forKey: Key.popupDuration) }
    }

    // MARK: - Panel type size

    /// Point size of the ledger's agent identifier, and through it every other size in the panel.
    ///
    /// One number rather than a set, because ``HerdLedgerScale`` derives the context size, the heading size,
    /// the row height, the gutter, the sigil diameters and every column ceiling from it at a fixed 7:6 ratio.
    /// Storing the derived values too would be storing the same fact several times and inviting them to
    /// disagree.
    ///
    /// Snapped to the nearest offered step on read rather than merely clamped to the range. A hand-edited
    /// plist holding 13.37 would otherwise produce derived sizes on thirds of a point, which quantise
    /// unevenly against the monospace grid, and the whole reason the control offers discrete steps is to
    /// prevent exactly that.
    public var ledgerTextSize: CGFloat {
        get {
            let stored = CGFloat(defaults.double(forKey: Key.ledgerTextSize))
            let steps = HerdLedgerScale.selectableIdentifierSizes
            guard let nearest = steps.min(by: { abs($0 - stored) < abs($1 - stored) }) else {
                return HerdLedgerScale.defaultIdentifierSize
            }
            return nearest
        }
        set { set(Double(newValue), forKey: Key.ledgerTextSize) }
    }

    /// The panel's whole size scale, derived from ``ledgerTextSize``.
    ///
    /// Resolved here so the host has one place that turns a stored number into the value `HerdPanelUI` takes,
    /// and so no view has to know that the number came from a preference at all.
    public var ledgerScale: HerdLedgerScale {
        HerdLedgerScale(identifierSize: ledgerTextSize)
    }

    // MARK: - Sessions

    /// Session names to show, empty meaning all of them.
    ///
    /// Applied in the model rather than in the views, so the status item roll-up and the list can
    /// never disagree about which sessions are in scope.
    ///
    /// The settings window lists **every discovered session** rather than only the ones passing this
    /// filter, which the right-click menu it replaced could not do: the menu was built from the already
    /// filtered snapshot, so a deselected session disappeared from the list and could never be selected
    /// again except by clearing the whole filter.
    public var sessionFilter: [String] {
        get { defaults.stringArray(forKey: Key.sessionFilter) ?? [] }
        set { set(newValue, forKey: Key.sessionFilter) }
    }

    // MARK: - Agent sources

    /// Which sources feed the panel. An unknown stored value reads as ``AgentSourceMode/both``.
    public var agentSourceMode: AgentSourceMode {
        get { AgentSourceMode(rawValue: defaults.string(forKey: Key.agentSourceMode) ?? "") ?? .both }
        set { set(newValue.rawValue, forKey: Key.agentSourceMode) }
    }

    /// Whether clicking a local agent tries to bring its terminal or IDE forward. herdr agents are unaffected.
    public var jumpToAgentEnabled: Bool {
        get { defaults.bool(forKey: Key.jumpToAgent) }
        set { set(newValue, forKey: Key.jumpToAgent) }
    }

    /// Upper bound of ``longTaskMinutes``, so a hand-edited plist cannot silence finish alerts for days.
    public static let maxLongTaskMinutes = 240

    /// Minutes a task must run before its finish is announced, clamped to `0...maxLongTaskMinutes`.
    public var longTaskMinutes: Int {
        get { min(max(defaults.integer(forKey: Key.longTaskMinutes), 0), Self.maxLongTaskMinutes) }
        set { set(newValue, forKey: Key.longTaskMinutes) }
    }

    // MARK: - Terminal

    /// Bundle identifier of the terminal to raise after focusing an agent, or `nil` to auto-detect.
    ///
    /// For a local agent it applies only when host detection finds nothing.
    ///
    /// A preference rather than a hard-coded value because which terminal hosts herdr is genuinely
    /// unknowable from the herdr API: `agent.list` reports an opaque `terminal_id` such as
    /// `term_657068fc62f8c2`, which names a herdr-side terminal record and not a macOS application.
    public var terminalBundleId: String? {
        get {
            let stored = defaults.string(forKey: Key.terminalBundleId) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set { set(newValue ?? "", forKey: Key.terminalBundleId) }
    }

    /// Whether to stamp `herdr: <session>` onto each attached terminal window when the panel opens.
    ///
    /// On by default, and turning it off costs two things the user should know about before they do, which
    /// is why it is stated here and in the settings window rather than left to be discovered:
    ///
    /// - **The `no terminal` marker disappears.** Attachment is only observable *because* of this write:
    ///   `client.window_title.set` cannot apply a title without a foreground client and says so, which is
    ///   the entire detection mechanism. With stamping off there is nothing to ask, so the panel stops
    ///   claiming to know and simply shows no marker.
    /// - **Cross-session window raising degrades to activating the application.** The stamped title is the
    ///   discriminator the window search matches on; herdr titles every attached window `herdr (herdr)`,
    ///   so without it two sessions are indistinguishable and clicking a row brings forward whichever
    ///   window the terminal happened to be showing.
    ///
    /// It exists because the probe is a write to the user's own window titles, and a write nobody asked
    /// for should be refusable.
    public var stampsWindowTitles: Bool {
        get { defaults.bool(forKey: Key.stampWindowTitles) }
        set { set(newValue, forKey: Key.stampWindowTitles) }
    }

    // MARK: - Remote sessions

    /// Whether ``remotePaths`` are scanned in addition to `~/.config/herdr`.
    ///
    /// A separate switch from the list itself, so a user can keep a configured forward around while
    /// turning off the scan, which is what you want while diagnosing whether a slow panel is the tunnel's
    /// fault.
    public var scansRemotePaths: Bool {
        get { defaults.bool(forKey: Key.remoteEnabled) }
        set { set(newValue, forKey: Key.remoteEnabled) }
    }

    /// Socket paths or directories holding sockets forwarded from other machines.
    ///
    /// See ``HerdrDiscovery/extraPaths`` for how each entry is interpreted and why this is the whole of
    /// the remote feature. In short: herdr's `--remote` is an attach mechanism, so a remote session's
    /// socket lives on the remote host; `ssh -L /local/path:/remote/path` brings an equivalent endpoint to
    /// a local path, and from there the existing discovery finds it with no new protocol code.
    public var remotePaths: [String] {
        get { defaults.stringArray(forKey: Key.remotePaths) ?? [] }
        set { set(newValue, forKey: Key.remotePaths) }
    }

    /// The paths discovery should actually scan: the configured list, or nothing when the scan is off.
    ///
    /// Resolved here rather than at each call site so the switch and the list can never be consulted
    /// separately and disagree.
    public var effectiveRemotePaths: [String] {
        scansRemotePaths ? remotePaths : []
    }

    // MARK: - Storage

    /// Announces the change, then writes it.
    ///
    /// The announcement comes first because `objectWillChange` is a *will*: SwiftUI reads the new value
    /// after the notification, and an observer that hops to the next main-actor turn (which the app
    /// delegate does) sees the written value either way.
    private func set(_ value: Any, forKey key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }
}
