import Foundation

/// Fetches plan-usage snapshots for every provider, keeping the last good reading and honoring 429 cooldowns.
///
/// Read-only: no token is ever refreshed or written. Callers poll (the plan says every 5 minutes) and must
/// not call `fetch` from the main thread's critical path; every call suspends, none blocks the caller.
public actor UsageFetcher {
    /// Cooldown after a 429 that carries no usable `Retry-After`.
    public static let defaultCooldown: TimeInterval = 5 * 60

    private let sources: [UsageProvider: any UsageSource]
    private let now: @Sendable () -> Date
    private var lastGood: [UsageProvider: UsageSnapshot] = [:]
    private var cooldownUntil: [UsageProvider: Date] = [:]
    private var inFlight: [UsageProvider: Task<UsageSnapshot, Never>] = [:]

    public init() {
        self.init(
            http: URLSessionHTTPClient(), loopbackHTTP: URLSessionHTTPClient(allowsInsecureLoopback: true),
            runner: SystemProcessRunner(), environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser, now: Date.init
        )
    }

    init(
        http: any HTTPClient,
        loopbackHTTP: any HTTPClient,
        runner: any ProcessRunner,
        environment: [String: String],
        home: URL,
        now: @escaping @Sendable () -> Date
    ) {
        let context = UsageContext(http: http, loopbackHTTP: loopbackHTTP, runner: runner, environment: environment, home: home)
        self.init(
            sources: [
                .claude: ClaudeUsageSource(context: context),
                .codex: CodexUsageSource(context: context),
                .openCode: OpenCodeUsageSource(context: context),
                .antigravity: AntigravityUsageSource(context: context)
            ],
            now: now
        )
    }

    init(sources: [UsageProvider: any UsageSource], now: @escaping @Sendable () -> Date) {
        self.sources = sources
        self.now = now
    }

    /// A concurrent call for the same provider joins the request already in flight.
    public func fetch(_ provider: UsageProvider) async -> UsageSnapshot {
        if let task = inFlight[provider] { return await task.value }
        let task = Task { await self.refresh(provider) }
        inFlight[provider] = task
        let snapshot = await task.value
        // Joiners resume too: clear only our own entry, never a newer request's.
        if inFlight[provider] == task { inFlight[provider] = nil }
        return snapshot
    }

    private func refresh(_ provider: UsageProvider) async -> UsageSnapshot {
        let started = now()
        if let until = cooldownUntil[provider], until > started {
            return carrying(provider, state: .rateLimited(until: until), at: started)
        }
        guard let source = sources[provider] else {
            return UsageSnapshot(provider: provider, state: .error("unsupported provider"), updatedAt: started)
        }
        do {
            let reading = try await source.load(now: started)
            let snapshot = UsageSnapshot(
                provider: provider, windows: reading.windows, plan: reading.plan, extra: reading.extra,
                state: .ok, updatedAt: started
            )
            lastGood[provider] = snapshot
            cooldownUntil[provider] = nil
            return snapshot
        } catch let failure as UsageFailure {
            return apply(failure, provider: provider, at: started)
        } catch {
            return carrying(provider, state: .error("request failed"), at: started)
        }
    }

    private func apply(_ failure: UsageFailure, provider: UsageProvider, at time: Date) -> UsageSnapshot {
        switch failure {
        case .notSetUp(let reason):
            lastGood[provider] = nil
            cooldownUntil[provider] = nil
            return UsageSnapshot(provider: provider, state: .notSetUp(reason: reason), updatedAt: time)
        case .stale(let reason):
            return carrying(provider, state: .stale(since: lastGood[provider]?.updatedAt ?? time, reason: reason), at: time)
        case .rateLimited(let retryAfter):
            let until = time.addingTimeInterval(max(retryAfter ?? Self.defaultCooldown, 1))
            cooldownUntil[provider] = until
            return carrying(provider, state: .rateLimited(until: until), at: time)
        case .failed(let message):
            return carrying(provider, state: .error(message), at: time)
        }
    }

    /// The last good values under a new state; `updatedAt` stays the time those values were read.
    private func carrying(_ provider: UsageProvider, state: UsageState, at time: Date) -> UsageSnapshot {
        guard var snapshot = lastGood[provider] else {
            return UsageSnapshot(provider: provider, state: state, updatedAt: time)
        }
        snapshot.state = state
        return snapshot
    }
}
