import Foundation
import HerdKit
import UserNotifications

/// Posts a system notification when an agent starts waiting on the human.
///
/// Blocked is the only status worth interrupting for: it is the one that sits there indefinitely
/// until someone answers it. `working` and `idle` resolve themselves.
///
/// The snapshot diff is not done here; ``HerdTransitionTracker`` does it once and hands the result to
/// both this type and the transient popup. What this type owns is the debounce and the delivery.
///
/// Thread-safety: main-actor isolated. The bookkeeping is plain mutable state touched only from the
/// poll loop and from the completion of its own delivery tasks, all of which are main-actor.
@MainActor
final class HerdBlockedNotifier {
    /// Minimum gap between two notifications about the same pane.
    ///
    /// One minute swallows a burst of consecutive prompts from one agent while still letting a
    /// genuinely new question ten minutes later through.
    private static let debounceInterval: TimeInterval = 60

    /// When each pane last produced a *delivered* notification, keyed by ``HerdTransition/key``.
    ///
    /// Only successful submissions are recorded. Recording on attempt would let a rejected
    /// notification silence that pane for a minute for no reason.
    private var lastNotified: [String: Date] = [:]

    /// Panes with a delivery in flight, so two ticks a second apart cannot both submit while the
    /// first is still awaiting authorization. Keyed by ``HerdTransition/key``.
    private var inFlight: Set<String> = []

    /// The notification centre, or `nil` when the process has no bundle identity to register with.
    ///
    /// `UNUserNotificationCenter.current()` traps rather than returning nil outside an app bundle,
    /// which is exactly what a bare `swift run` is. Resolving it defensively keeps the app debuggable
    /// from the command line, just without notifications.
    private let center: UNUserNotificationCenter?

    /// The single in-flight or completed authorization request.
    ///
    /// Held as a `Task` so concurrent callers all await the same request rather than each firing
    /// their own, and so an alert raised moments after launch waits for the answer instead of being
    /// dropped against a not-yet-known authorization state.
    private var authorization: Task<Bool, Never>?

    /// Creates a notifier. Does not request authorization; call ``requestAuthorization()`` once the
    /// app has launched, so the system prompt does not appear before the menu bar item does.
    init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Starts the authorization request early, so the first real alert does not have to wait on it.
    ///
    /// Fire and forget: the result is cached and awaited by ``notify(_:isEnabled:)``.
    func requestAuthorization() {
        Task { _ = await authorized() }
    }

    /// Posts a notification for each agent that has just become blocked.
    ///
    /// - Parameters:
    ///   - transitions: This tick's status changes, from ``HerdTransitionTracker``.
    ///   - isEnabled: The `herdNotifyOnBlocked` preference.
    func notify(_ transitions: [HerdTransition], isEnabled: Bool) {
        guard isEnabled, center != nil else { return }
        let now = Date()
        // Any transition into blocked notifies, including from `unknown`: for the system notification
        // a false positive costs one banner, whereas a missed blocked agent costs the user an agent
        // stuck waiting. The transient popup makes the opposite trade, because it is the noisier
        // surface and appears unprompted in the corner of the screen.
        for transition in transitions where transition.to == .blocked && transition.from != .blocked {
            let key = transition.key
            guard !inFlight.contains(key) else { continue }
            if let last = lastNotified[key], now.timeIntervalSince(last) < Self.debounceInterval {
                continue
            }
            inFlight.insert(key)
            Task { await deliver(transition, key: key) }
        }
    }

    /// Awaits authorization and submits one notification, recording the debounce entry only if the
    /// submission actually succeeded.
    ///
    /// - Parameters:
    ///   - transition: The blocked transition to announce.
    ///   - key: Its session-scoped identity key.
    private func deliver(_ transition: HerdTransition, key: String) async {
        defer { inFlight.remove(key) }
        guard await authorized(), let center else { return }

        let agent = transition.agent
        let content = UNMutableNotificationContent()
        // Same vocabulary as the row tooltip and the transient popup.
        content.title = "\(agent.displayIdentifier) is waiting for you"
        content.body = "\(agent.agent) · \(transition.sessionName) · \(agent.paneId)"
        content.sound = .default

        // A fresh identifier per delivery so two prompts from the same pane a minute apart both
        // appear, instead of the second replacing the first in Notification Center. The session name
        // is still in the identifier so two sessions sharing a pane id stay distinguishable.
        let request = UNNotificationRequest(
            identifier: "herd.blocked.\(transition.sessionName).\(agent.paneId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            lastNotified[key] = Date()
        } catch {
            Self.log("could not post notification: \(error)")
        }
    }

    /// Whether the user has granted notification permission, requesting it once if not yet asked.
    ///
    /// Authorization can legitimately be refused outright for an ad-hoc signed, non-App-Store bundle:
    /// the system decides, and a bundle it does not recognise may never be granted. That is reported
    /// once and then treated as a permanent no, because the panel is fully usable without it.
    ///
    /// - Returns: `true` when notifications may be posted.
    private func authorized() async -> Bool {
        if let existing = authorization { return await existing.value }
        guard let center else {
            Self.log("no bundle identity, notifications disabled")
            let denied = Task<Bool, Never> { false }
            authorization = denied
            return await denied.value
        }
        let task = Task<Bool, Never> {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted { Self.log("notifications not authorized") }
                return granted
            } catch {
                Self.log("notification authorization failed: \(error)")
                return false
            }
        }
        authorization = task
        return await task.value
    }

    /// Writes one diagnostic line to standard error.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("herd: \(message)\n".utf8))
    }
}
