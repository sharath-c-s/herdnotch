import EventKit
import Foundation

/// EventKit reminders: authorization, an incomplete-reminders list, and adding one.
///
/// A concrete type despite the "protocol only where a boundary genuinely needs stubbing" rule elsewhere in
/// this target's services, because EventKit's own authorization flow is exactly the boundary that rule
/// carves out as the exception — there is no way to unit test a real consent prompt, so a protocol seam
/// here would only ever have one production implementation and a fake that asserts nothing interesting.
///
/// Every EventKit entry point that can fail (denied authorization, a save error) degrades to a published
/// state the UI can show — "grant access in System Settings" — rather than throwing or crashing; a notch
/// surface a user glances at for a few seconds must never wedge on a permission dialog or an unhandled
/// error.
///
/// Thread-safety: `@MainActor` for every published property, since `NotchContentView` reads them directly.
/// `EKEventStore`'s own async APIs (`requestFullAccessToReminders(completion:)`,
/// `fetchReminders(matching:completion:)`) already hop off the calling thread internally and call back on
/// an arbitrary queue, so every completion handler below explicitly re-enters the main actor with
/// `Task { @MainActor in }` before touching published state, the same idiom `NotchCommandExecutor`'s timer
/// and monitor callbacks use for the same reason.
@MainActor
final class RemindersService: ObservableObject {
    /// What the interface is allowed to say about Reminders access.
    ///
    /// Collapsed from `EKAuthorizationStatus`'s six cases (`notDetermined`, `restricted`, `denied`,
    /// `fullAccess`, `writeOnly`, and the deprecated `authorized`) to three, because this surface only ever
    /// needs to choose between "still deciding", "cannot read or write" and "can read and write" — a
    /// `writeOnly` grant (meaningful for calendar events, not something Reminders itself distinguishes in
    /// practice) and `restricted` both fall into `.denied` here, since neither lets this service do
    /// anything a `.denied` state could not equally say "grant access" about.
    enum AuthorizationState: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    /// A reminder, reduced to what the notch surface actually renders. Deliberately not `EKReminder`
    /// itself: `EKReminder` is a mutable, `NSObject`-backed EventKit type with no `Identifiable` or
    /// `Equatable` conformance of its own, and `NotchContentView` should not have to import EventKit (it
    /// otherwise imports only `HerdKit`, `HerdPanelUI`, `NotchCore`, `NotchGeometry` and `SwiftUI`) just to
    /// render a list of titles.
    struct ReminderItem: Identifiable, Equatable {
        /// `EKReminder.calendarItemIdentifier`, stable across a fetch-and-refetch of the same reminder.
        let id: String
        let title: String
        /// `EKReminder.dueDateComponents`'s own `Date`, or `nil` for a reminder with no due date. Drives both
        /// ``sorted(_:now:)`` (overdue-first, then soonest-due-first) and the Ledger+Rail rail's overdue date
        /// suffix.
        let dueDate: Date?
        /// `EKReminder.creationDate`. Falls back to ``sorted(_:now:)``'s tiebreak for a reminder with no due
        /// date, so a freshly added reminder (which has none until the user sets one) still sorts to the top
        /// of that tier rather than the bottom.
        let creationDate: Date?
    }

    /// Current authorization, read by ``RemindersService`` UI to choose between an access-request message,
    /// a denial message, or the live list.
    @Published private(set) var authorizationState: AuthorizationState = .notDetermined

    /// Every incomplete reminder across every list, in creation order. Empty (rather than `nil`) both before
    /// the first successful fetch and once access is denied, so the UI never needs a third "no data yet"
    /// state beyond ``authorizationState`` itself.
    @Published private(set) var items: [ReminderItem] = []

    /// The one event store this service ever creates. A single instance, not one per call: EventKit expects
    /// callers to reuse a store rather than build a fresh one per operation, and this is also what lets
    /// ``changeObserver`` scope its notification to store-originated changes.
    private let store = EKEventStore()

    /// Notifies ``refresh()`` whenever Reminders.app (or any other EventKit client, including this one's own
    /// ``addReminder(title:)``) changes a reminder — this is what makes "completing a reminder in
    /// Reminders.app clears it here" work with no polling of this service's own.
    ///
    /// The returned token is intentionally never held or removed: `NotchWindowController` builds exactly one
    /// `RemindersService` and keeps it for the process's entire lifetime (mirroring ``herdModel`` and
    /// ``caffeinateService``), so there is no "this instance goes away, tear down its observer" moment to
    /// handle — the same reasoning `HerdGlobalHotKey`'s own documentation gives for having no `deinit` at
    /// all: the registration's true lifetime is the process, which cleans it up by exiting.
    private func startObservingChanges() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Creates the service and starts observing `EKEventStoreChanged`. Requests no authorization yet; see
    /// ``start()``.
    init() {
        startObservingChanges()
    }

    /// Reads the current authorization status and sets ``authorizationState`` accordingly, fetching
    /// immediately when access is already granted. Called once, from `NotchWindowController.start()`.
    ///
    /// **Does not itself request access on `.notDetermined`.** It used to: the very first launch would
    /// silently pop the system consent dialog before the user had asked for anything, which is the opposite
    /// of the Ledger+Rail design spec's reminders section, which shows a `.notDetermined` state with its own
    /// explicit "Allow access" button — a UI can only offer that choice if *something* is stopping this
    /// service from jumping the gun and requesting on its own first. ``requestAccess()`` is now `public`
    /// specifically so that button, not this method, is what triggers the prompt.
    func start() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined:
            authorizationState = .notDetermined
        case .fullAccess:
            authorizationState = .authorized
            refresh()
        default:
            // `.restricted`, `.denied`, `.writeOnly`, and the deprecated `.authorized` (which
            // `authorizationStatus(for:)` no longer returns once an app has adopted
            // `requestFullAccessToReminders`, per Apple's migration notes) all land here — see
            // ``AuthorizationState``'s own documentation for why none of them earns a distinct case.
            authorizationState = .denied
        }
    }

    /// Prompts the user for Reminders access, macOS 14's full-access API (the package's `.macOS(.v14)`
    /// minimum means there is no older fallback to carry).
    ///
    /// `public`, and meant to be called directly from the notch surface's "Allow access" button (the
    /// `.notDetermined` state of the Ledger+Rail reminders section) rather than automatically from
    /// ``start()`` — see that method's own documentation for why the two were split.
    ///
    /// Routed through ``requestFullAccess(store:completion:)`` rather than calling
    /// `store.requestFullAccessToReminders(completion:)` directly here — see that function's own
    /// documentation for why a closure literal written directly in this (`@MainActor`-isolated) method would
    /// crash the instant EventKit actually invokes it.
    func requestAccess() {
        Self.requestFullAccess(store: store) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    FileHandle.standardError.write(
                        Data("herdnotch: reminders authorization request failed: \(error)\n".utf8)
                    )
                }
                self.authorizationState = granted ? .authorized : .denied
                if granted { self.refresh() }
            }
        }
    }

    /// Re-fetches every incomplete reminder across every list. A no-op while not authorized, so a stray
    /// `EKEventStoreChanged` arriving before (or after) access is granted cannot trigger an EventKit call
    /// that would just fail again.
    ///
    /// Routed through ``fetchIncompleteReminders(store:predicate:completion:)`` for the same reason
    /// ``requestAccess()`` is — see that function's documentation for the crash this avoids.
    func refresh() {
        guard authorizationState == .authorized else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        Self.fetchIncompleteReminders(store: store, predicate: predicate) { [weak self] mapped in
            Task { @MainActor in self?.items = mapped }
        }
    }

    /// Runs `EKEventStore.requestFullAccessToReminders(completion:)` and forwards its result to
    /// `completion`.
    ///
    /// **Why this indirection exists, and it is not cosmetic — this is the fix for a real crash.** EventKit
    /// invokes both `requestFullAccessToReminders(completion:)`'s and `fetchReminders(matching:completion:)`'s
    /// completion handlers on an arbitrary background queue, never the main queue. Neither completion
    /// parameter is declared `@Sendable` in EventKit's overlay, so a closure literal written directly inside
    /// a `@MainActor`-isolated instance method (as ``requestAccess()`` and ``refresh()`` originally did)
    /// inherits `@MainActor` isolation from that enclosing method by Swift's own actor-isolation-inference
    /// rule — regardless of whether the closure body actually touches any main-actor state itself. The
    /// compiler enforces that inferred isolation with a runtime check at the top of the closure body, and
    /// that check trips a `SIGTRAP` (`dispatch_assert_queue_fail` inside `swift_task_checkIsolatedSwift`)
    /// the moment EventKit calls the closure from its own off-main queue — reproduced and confirmed against
    /// `HerdNotch.app` while implementing this method: launching with reminders authorization already
    /// determined ended in an immediate crash inside exactly this call path.
    ///
    /// Declaring this a `nonisolated static` function breaks the inference: a closure literal written here
    /// has no enclosing actor to inherit, so it runs correctly on whatever queue EventKit invokes it from.
    /// `completion`'s type is explicitly `@escaping @Sendable`, which is what lets the *caller's* own closure
    /// literal (in ``requestAccess()``, still lexically inside the `@MainActor` class) skip the same
    /// inference too — a `@Sendable`-typed parameter overrides isolation inference regardless of where the
    /// argument closure is written, and a `[weak self]` capture of a non-`Sendable` class is a
    /// compiler-recognised exception to `@Sendable`'s usual "every capture must be `Sendable`" rule.
    ///
    /// - Parameters:
    ///   - store: The event store to request access on, passed in rather than read from `self.store` so
    ///     this `nonisolated` function never needs to touch actor-isolated instance state.
    ///   - completion: Forwarded verbatim to EventKit's own completion handler.
    private nonisolated static func requestFullAccess(
        store: EKEventStore, completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        store.requestFullAccessToReminders(completion: completion)
    }

    /// Runs `EKEventStore.fetchReminders(matching:completion:)`, maps the result to ``ReminderItem`` off the
    /// main actor, and forwards the mapped array to `completion`.
    ///
    /// See ``requestFullAccess(store:completion:)``'s documentation for why this is a `nonisolated static`
    /// function with an explicitly `@Sendable` `completion` parameter rather than a closure written directly
    /// in ``refresh()`` — this is the exact crash that method's documentation describes, reproduced against
    /// this call path specifically. The sort and map run here, off the main actor, rather than after hopping
    /// back in `refresh()`'s own `Task { @MainActor in }`: sorting is pure and read-only over EventKit's own
    /// result array, so there is no reason to hold up the main actor for it.
    ///
    /// - Parameters:
    ///   - store: The event store to fetch from.
    ///   - predicate: The fetch predicate, built by the caller (`NSPredicate` construction itself must
    ///     happen on the main actor per `EKEventStore`'s own documentation, hence it is a parameter here
    ///     rather than built inside this function).
    ///   - completion: Receives the mapped, creation-ordered list.
    private nonisolated static func fetchIncompleteReminders(
        store: EKEventStore, predicate: NSPredicate, completion: @escaping @Sendable ([ReminderItem]) -> Void
    ) {
        store.fetchReminders(matching: predicate) { reminders in
            let mapped = (reminders ?? []).map {
                ReminderItem(
                    id: $0.calendarItemIdentifier,
                    title: $0.title ?? "",
                    dueDate: $0.dueDateComponents?.date,
                    creationDate: $0.creationDate
                )
            }
            completion(sorted(mapped, now: Date()))
        }
    }

    /// Orders reminders overdue-first, then soonest-due-first, then (for reminders with no due date at all)
    /// most-recently-created first — the Ledger+Rail design spec's "overdue → due date → creation" sort,
    /// with the third tier read as newest-first specifically so a reminder just added through the quick-add
    /// field (which sets no due date) lands at the top of the list rather than the bottom, per that spec's
    /// "new item tops the list" requirement for the quick-add flow.
    ///
    /// `nonisolated`, like ``fetchIncompleteReminders(store:predicate:completion:)`` that calls it: sorting
    /// is pure and read-only, so it runs off the main actor alongside the fetch and map it is part of, rather
    /// than adding a hop back onto the main actor just to sort an already-mapped array.
    ///
    /// - Parameters:
    ///   - items: The reminders to order.
    ///   - now: The instant "overdue" is measured against, passed in rather than read from `Date()` inside
    ///     this function so a test can pin it.
    /// - Returns: `items`, reordered.
    private nonisolated static func sorted(_ items: [ReminderItem], now: Date) -> [ReminderItem] {
        func tier(_ item: ReminderItem) -> Int {
            guard let due = item.dueDate else { return 2 }
            return due < now ? 0 : 1
        }
        return items.sorted { lhs, rhs in
            let lhsTier = tier(lhs)
            let rhsTier = tier(rhs)
            guard lhsTier == rhsTier else { return lhsTier < rhsTier }
            switch lhsTier {
            case 0, 1:
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            default:
                return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
            }
        }
    }

    /// Creates a reminder titled `title` in the default reminders list and refreshes ``items``.
    ///
    /// - Parameter title: The reminder's title. Whitespace-only input is dropped silently — the Enter-to-add
    ///   text field is expected to call this on every submit, including an accidental empty one.
    func addReminder(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, authorizationState == .authorized else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = store.defaultCalendarForNewReminders()
        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            FileHandle.standardError.write(Data("herdnotch: failed to save reminder: \(error)\n".utf8))
        }
    }

    /// Marks `reminder` complete via EventKit and removes it from ``items`` immediately, rather than waiting
    /// for the EventKit round trip below (or the ``refresh()`` at the end of it) to confirm the removal.
    ///
    /// **This replaces the previous implementation's root cause for "ticking a reminder's circle doesn't
    /// always complete it".** That version resolved `reminder.id` back to a live `EKReminder` with
    /// `store.calendarItem(withIdentifier:)` — a synchronous, local-cache-only lookup that Apple's own
    /// documentation warns can return `nil` for an item EventKit has not (or no longer) cached, independent
    /// of whether the reminder still exists. When that happened here, the guard silently returned before
    /// ever calling `store.save`, so nothing was committed and no error surfaced — the tap's optimistic
    /// checkmark animation (in `NotchContentView.completeReminder(_:)`) played anyway, then the reminder
    /// popped right back on the next fetch, exactly the intermittent "sometimes it just doesn't take"
    /// behaviour reported. Resolving the identifier instead through a fresh
    /// ``completeReminder(store:identifier:predicate:completion:)`` call — the same authoritative
    /// `fetchReminders(matching:completion:)` source ``refresh()`` itself uses — cannot miss a reminder that
    /// genuinely still exists, because it is not reading from a cache at all.
    ///
    /// Removing `reminder` from ``items`` up front (rather than only after the fetch-then-save below and
    /// the ``refresh()`` that follows it) is the optimistic-removal half of the fix: a tap should clear the
    /// row immediately, not after a round trip to EventKit. If the save then fails for a genuine reason (the
    /// reminder was deleted elsewhere in the meantime, say), the unconditional ``refresh()`` in the
    /// completion handler reconciles ``items`` back to whatever EventKit actually has, so the optimistic
    /// removal can never strand ``items`` in a state EventKit disagrees with.
    ///
    /// - Parameter reminder: The item to complete, as published in ``items``.
    func complete(_ reminder: ReminderItem) {
        guard authorizationState == .authorized else { return }
        items.removeAll { $0.id == reminder.id }
        let predicate = store.predicateForReminders(in: nil)
        Self.completeReminder(store: store, identifier: reminder.id, predicate: predicate) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    FileHandle.standardError.write(
                        Data("herdnotch: failed to complete reminder: \(error)\n".utf8)
                    )
                }
                self.refresh()
            }
        }
    }

    /// Runs `EKEventStore.fetchReminders(matching:completion:)` to locate the reminder whose
    /// `calendarItemIdentifier` is `identifier`, marks it complete, and saves it.
    ///
    /// This fetch-then-save pairing is what ``complete(_:)`` uses in place of the unreliable
    /// `calendarItem(withIdentifier:)` cache lookup its own documentation describes — see that method's
    /// documentation for the crash this class of bug reproduced.
    ///
    /// `nonisolated static` with an explicit `@Sendable` `completion`, for the same reason
    /// ``requestFullAccess(store:completion:)`` and ``fetchIncompleteReminders(store:predicate:completion:)``
    /// are: EventKit invokes `fetchReminders(matching:completion:)`'s completion handler from an arbitrary
    /// background queue, and a closure literal written directly inside a `@MainActor`-isolated method would
    /// inherit that isolation and crash the instant EventKit calls it from off-main.
    ///
    /// - Parameters:
    ///   - store: The event store to fetch and save through.
    ///   - identifier: The `calendarItemIdentifier` of the reminder to complete.
    ///   - predicate: Matches every reminder — complete or not, in every calendar — rather than
    ///     ``refresh()``'s incomplete-only predicate, since a reminder some other EventKit client already
    ///     completed a moment ago must still resolve here rather than silently fail to be found.
    ///   - completion: Receives `nil` on success, or the error that made completion fail — "identifier not
    ///     found" is reported as an explicit `NSError`, not a silent no-op.
    private nonisolated static func completeReminder(
        store: EKEventStore, identifier: String, predicate: NSPredicate,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        store.fetchReminders(matching: predicate) { reminders in
            guard let match = reminders?.first(where: { $0.calendarItemIdentifier == identifier }) else {
                completion(
                    NSError(
                        domain: "herdnotch.reminders", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "reminder \(identifier) not found"]
                    )
                )
                return
            }
            match.isCompleted = true
            do {
                try store.save(match, commit: true)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}
