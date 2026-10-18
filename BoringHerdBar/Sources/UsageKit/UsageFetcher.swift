import Foundation

/// Fetches plan-usage snapshots for every provider, keeping the last good reading and honoring 429 cooldowns.
///
/// Read-only: no token is ever refreshed or written. Callers poll (the plan says every 5 minutes) and must
/// not call `fetch` from the main thread's critical path; every call suspends, none blocks the caller.
public actor UsageFetcher {
    /// Cooldown after a 429 that carries no `Retry-After`.
    public static let defaultCooldown: TimeInterval = 5 * 60
    /// A provider that has not answered by then is abandoned for this pass; the next pass tries it again.
    public static let fetchTimeout: TimeInterval = 120
    /// How long a non-forced fetch reuses the latest answer; matches the poll interval, so only the timer hits the network.
    /// Just above the 5-min poll plus its timer leeway, so an open right before the timer fires reuses.
    public static let reuseInterval: TimeInterval = 6 * 60

    private let sources: [UsageProvider: any UsageSource]
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private let store: UsageStore?
    private var lastGood: [UsageProvider: UsageSnapshot] = [:]
    /// The previous run's readings. Not last-good: a live success replaces them, and only a first 429 promotes one.
    private var launchSnapshots: [UsageProvider: UsageSnapshot] = [:]
    /// In memory only: a relaunch always fetches.
    private var cooldownUntil: [UsageProvider: Date] = [:]
    private var inFlight: [UsageProvider: Task<UsageSnapshot, Never>] = [:]
    /// Bumped when a refresh is abandoned at the deadline; a refresh holding an older value applies nothing.
    private var generation: [UsageProvider: Int] = [:]
    /// Each provider's latest answer, whatever its state, reused by non-forced fetches for ``reuseInterval``.
    private var latest: [UsageProvider: (snapshot: UsageSnapshot, at: Date)] = [:]

    public init() {
        self.init(
            http: URLSessionHTTPClient(), loopbackHTTP: URLSessionHTTPClient(allowsInsecureLoopback: true),
            runner: SystemProcessRunner(), environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser, now: Date.init,
            store: UsageStore(url: UsageStore.defaultURL)
        )
    }

    init(
        http: any HTTPClient,
        loopbackHTTP: any HTTPClient,
        runner: any ProcessRunner,
        environment: [String: String],
        home: URL,
        now: @escaping @Sendable () -> Date,
        store: UsageStore? = nil
    ) {
        let context = UsageContext(http: http, loopbackHTTP: loopbackHTTP, runner: runner, environment: environment, home: home)
        self.init(
            sources: [
                .claude: ClaudeUsageSource(context: context),
                .codex: CodexUsageSource(context: context),
                .openCode: OpenCodeUsageSource(context: context),
                .antigravity: AntigravityUsageSource(context: context)
            ],
            now: now,
            store: store
        )
    }

    init(
        sources: [UsageProvider: any UsageSource],
        now: @escaping @Sendable () -> Date,
        store: UsageStore? = nil,
        timeout: TimeInterval = UsageFetcher.fetchTimeout
    ) {
        self.sources = sources
        self.now = now
        self.store = store
        self.timeout = timeout
        for (key, snapshot) in store?.load().snapshots ?? [:] {
            if let provider = UsageProvider(rawValue: key) { launchSnapshots[provider] = snapshot }
        }
    }

    /// The previous run's readings, so the cards can show numbers before the first fetch lands.
    public func persistedSnapshots() -> [UsageProvider: UsageSnapshot] { launchSnapshots }

    /// A concurrent call for the same provider joins the request already in flight. With `force` false, an answer
    /// younger than ``reuseInterval`` is returned as is, so UI-triggered refreshes never reach a throttled endpoint.
    public func fetch(_ provider: UsageProvider, force: Bool = true) async -> UsageSnapshot {
        if !force, inFlight[provider] == nil, let last = latest[provider],
            now().timeIntervalSince(last.at) < Self.reuseInterval {
            return last.snapshot
        }
        let task: Task<UsageSnapshot, Never>
        if let running = inFlight[provider] {
            task = running
        } else {
            let mine = generation[provider, default: 0]
            task = Task { await self.refresh(provider, generation: mine) }
            inFlight[provider] = task
        }
        let answer = await withDeadline(task)
        // Joiners resume too: clear only our own entry, never a newer request's.
        if inFlight[provider] == task { inFlight[provider] = nil }
        let snapshot: UsageSnapshot
        if let answer {
            snapshot = answer
        } else {
            task.cancel()
            generation[provider, default: 0] += 1
            snapshot = carrying(provider, state: .error("timed out after \(Int(timeout))s"), at: now())
        }
        latest[provider] = (snapshot, now())
        return snapshot
    }

    /// Nil when `timeout` passes first. Unstructured on purpose: a hung source must not hold the caller.
    private func withDeadline(_ task: Task<UsageSnapshot, Never>) async -> UsageSnapshot? {
        let seconds = timeout
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.install(continuation)
            race.setSleeper(Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.finish(nil)
            })
            Task { race.finish(await task.value) }
        }
    }

    private func refresh(_ provider: UsageProvider, generation mine: Int) async -> UsageSnapshot {
        let started = now()
        if let until = cooldownUntil[provider], until > started {
            return carrying(provider, state: .rateLimited(until: until), at: started)
        }
        guard let source = sources[provider] else {
            return UsageSnapshot(provider: provider, state: .error("unsupported provider"), updatedAt: started)
        }
        do {
            let reading = try await source.load(now: started)
            if abandoned(provider, mine) { return discarded(provider, at: started) }
            let snapshot = UsageSnapshot(
                provider: provider, windows: reading.windows, plan: reading.plan, extra: reading.extra,
                state: .ok, updatedAt: started
            )
            lastGood[provider] = snapshot
            launchSnapshots[provider] = nil
            cooldownUntil[provider] = nil
            persist()
            return snapshot
        } catch let failure as UsageFailure {
            if abandoned(provider, mine) { return discarded(provider, at: started) }
            return apply(failure, provider: provider, at: started)
        } catch {
            if abandoned(provider, mine) { return discarded(provider, at: started) }
            return carrying(provider, state: .error("request failed"), at: started)
        }
    }

    private func abandoned(_ provider: UsageProvider, _ mine: Int) -> Bool {
        generation[provider, default: 0] != mine
    }

    /// Nobody awaits an abandoned refresh's answer; it must not touch last-good, the cooldown or the file.
    private func discarded(_ provider: UsageProvider, at time: Date) -> UsageSnapshot {
        carrying(provider, state: .error("abandoned"), at: time)
    }

    private func apply(_ failure: UsageFailure, provider: UsageProvider, at time: Date) -> UsageSnapshot {
        switch failure {
        case .notSetUp(let reason):
            lastGood[provider] = nil
            launchSnapshots[provider] = nil
            cooldownUntil[provider] = nil
            persist()
            return UsageSnapshot(provider: provider, state: .notSetUp(reason: reason), updatedAt: time)
        case .stale(let reason):
            let since = (lastGood[provider] ?? launchDisplay(provider, at: time))?.updatedAt ?? time
            return carrying(provider, state: .stale(since: since, reason: reason), at: time)
        case .rateLimited(let retryAfter):
            let until = time.addingTimeInterval(retryAfter ?? Self.defaultCooldown)
            cooldownUntil[provider] = until
            promoteLaunchSnapshot(provider, at: time)
            return carrying(provider, state: .rateLimited(until: until), at: time)
        case .failed(let message):
            return carrying(provider, state: .error(message), at: time)
        }
    }

    /// Lets a relaunch's first 429 keep the persisted numbers instead of blanking the card. Windows that already
    /// reset are dropped, since their stored percentage no longer applies; with none left, nothing is adopted.
    /// ponytail: Claude only, and no account match. Snapshots carry no account id, so a swapped login shows the
    /// old account's numbers until the first successful fetch; add an identity to the cache entry to close that.
    private func promoteLaunchSnapshot(_ provider: UsageProvider, at time: Date) {
        guard provider == .claude, lastGood[provider] == nil, var snapshot = launchSnapshots[provider] else { return }
        launchSnapshots[provider] = nil
        snapshot.windows.removeAll { window in window.resetsAt.map { $0 <= time } ?? false }
        guard !snapshot.windows.isEmpty else { return }
        lastGood[provider] = snapshot
    }

    private func persist() {
        guard let store else { return }
        var persisted = PersistedUsage()
        for (provider, snapshot) in launchSnapshots { persisted.snapshots[provider.rawValue] = snapshot }
        for (provider, snapshot) in lastGood { persisted.snapshots[provider.rawValue] = snapshot }
        store.save(persisted)
    }

    /// The previous run's reading minus windows that already reset; nil when nothing usable is left.
    private func launchDisplay(_ provider: UsageProvider, at time: Date) -> UsageSnapshot? {
        guard var snapshot = launchSnapshots[provider] else { return nil }
        snapshot.windows.removeAll { window in window.resetsAt.map { $0 <= time } ?? false }
        return snapshot.windows.isEmpty ? nil : snapshot
    }

    /// The last good values under a new state; `updatedAt` stays the time those values were read. Before the first
    /// live success it falls back to the previous run's reading, for display only: it never becomes last-good here.
    private func carrying(_ provider: UsageProvider, state: UsageState, at time: Date) -> UsageSnapshot {
        guard var snapshot = lastGood[provider] ?? launchDisplay(provider, at: time) else {
            return UsageSnapshot(provider: provider, state: state, updatedAt: time)
        }
        snapshot.state = state
        return snapshot
    }
}

/// Resumes its continuation once, whichever of the request or the deadline gets there first.
private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UsageSnapshot?, Never>?
    private var sleeper: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<UsageSnapshot?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func setSleeper(_ task: Task<Void, Never>) {
        lock.withLock { sleeper = task }
    }

    func finish(_ value: UsageSnapshot?) {
        let (pending, timer) = lock.withLock { () -> (CheckedContinuation<UsageSnapshot?, Never>?, Task<Void, Never>?) in
            defer { continuation = nil }
            return (continuation, sleeper)
        }
        guard let pending else { return }
        timer?.cancel()
        pending.resume(returning: value)
    }
}
