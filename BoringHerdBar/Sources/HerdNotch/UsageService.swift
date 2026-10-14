import Combine
import Foundation
import UsageKit

/// Polls plan usage for the enabled providers every 5 minutes, off the main thread, and publishes the latest snapshots.
///
/// No timer exists while every provider is disabled. ``refreshIfStale(maxAge:)`` lets the System page pull a
/// fresh reading when it opens.
@MainActor
final class UsageService: ObservableObject {
    static let pollInterval: TimeInterval = 5 * 60

    @Published private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]
    let events = PassthroughSubject<UsageEvent, Never>()

    private let fetcher: UsageFetcher
    private var enabled: Set<UsageProvider> = []
    private var warn = 80.0
    private var critical = 95.0
    private var timer: DispatchSourceTimer?
    private var tracker = UsageAlertTracker()
    private var lastRefresh: Date?
    private var inFlight: Set<UsageProvider> = []

    init(fetcher: UsageFetcher = UsageFetcher()) {
        self.fetcher = fetcher
    }

    deinit { timer?.cancel() }

    func configure(enabled providers: Set<UsageProvider>, warnPercent: Int, criticalPercent: Int) {
        warn = Double(warnPercent)
        critical = Double(criticalPercent)
        guard providers != enabled else { return }
        let added = !providers.subtracting(enabled).isEmpty
        for removed in enabled.subtracting(providers) {
            snapshots[removed] = nil
            tracker.forget(removed)
        }
        enabled = providers
        if providers.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        startTimerIfNeeded()
        if added { refresh() }
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !enabled.isEmpty else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    /// Fetches every enabled provider in its own task, so one provider's slow Keychain prompt never holds
    /// back the others' results; a provider still in flight is skipped.
    func refresh() {
        guard !enabled.isEmpty else { return }
        lastRefresh = Date()
        let fetcher = fetcher
        for provider in enabled where !inFlight.contains(provider) {
            inFlight.insert(provider)
            Task { [weak self] in
                let snapshot = await fetcher.fetch(provider)
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: UsageSnapshot) {
        inFlight.remove(snapshot.provider)
        guard enabled.contains(snapshot.provider) else { return }
        snapshots[snapshot.provider] = snapshot
        for event in tracker.update(snapshot, warn: warn, critical: critical, now: Date()) {
            events.send(event)
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .seconds(30))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = source
        source.resume()
    }
}
