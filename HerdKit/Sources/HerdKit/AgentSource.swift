import Foundation

/// A provider of agent sessions for the panel. Synchronous and blocking like ``HerdSnapshotBuilder``,
/// so callers run it off the main thread.
public protocol AgentSource: Sendable {
    /// Current sessions. Never throws: failures become per-session errors or an empty list.
    func sessions() -> [HerdSession]
}

/// Which sources feed the panel.
public enum AgentSourceMode: String, Codable, Sendable, CaseIterable {
    case herdr
    case local
    case both
}

/// herdr as an ``AgentSource``: the existing ``HerdSnapshotBuilder`` path, unchanged.
public struct HerdrSource: AgentSource {
    private let builder: HerdSnapshotBuilder

    public init(builder: HerdSnapshotBuilder = HerdSnapshotBuilder()) {
        self.builder = builder
    }

    public func sessions() -> [HerdSession] {
        builder.build().sessions
    }
}

/// Combines herdr sessions with the local session. Pure, so every mode is testable without I/O.
public enum AgentSourceMerge {
    /// - Parameters:
    ///   - herdr: Sessions from herdr, in display order. Empty when herdr is down.
    ///   - local: The `local` session, `nil` when no local agents exist.
    ///   - mode: `herdr` returns only `herdr`, `local` only `local`. `both` returns herdr sessions in their
    ///     order with `local` appended last, after dropping local agents herdr already reports: those with
    ///     ``HerdAgent/parentChainHasHerdr``, or whose ``HerdAgent/agentSessionID`` equals any herdr agent's.
    ///     A local session left with no agents is omitted.
    public static func merge(herdr: [HerdSession], local: HerdSession?, mode: AgentSourceMode) -> [HerdSession] {
        switch mode {
        case .herdr:
            return herdr
        case .local:
            return nonEmpty(local).map { [$0] } ?? []
        case .both:
            let known = knownSessionIds(herdr)
            guard let local else { return herdr }
            var kept = local
            kept.workspaces = local.workspaces.compactMap { workspace in
                var copy = workspace
                copy.agents = workspace.agents.filter { !isDuplicate($0, knownSessionIds: known) }
                return copy.agents.isEmpty ? nil : copy
            }
            guard let merged = nonEmpty(kept) else { return herdr }
            return herdr + [HerdSession(
                name: localName(avoiding: herdr.map(\.name), base: merged.name), isDefault: merged.isDefault, running: merged.running, socketPath: merged.socketPath,
                isRemote: merged.isRemote, workspaces: merged.workspaces, error: merged.error)]
        }
    }

    /// One blocking snapshot for `mode`: herdr only is the builder's own result, anything else merges in the
    /// local session (skipped, with its transcript reads, when `wantsLocal` is false). Run off the main thread.
    public static func snapshot(
        mode: AgentSourceMode, wantsLocal: Bool, builder: HerdSnapshotBuilder, local: LocalAgentSource
    ) -> HerdSnapshot {
        guard mode != .herdr else { return builder.build() }
        let herdr = mode == .local ? [] : HerdrSource(builder: builder).sessions()
        // Agents the merge would drop never reach the transcript reader.
        let known = knownSessionIds(herdr)
        let localSession = wantsLocal
            ? local.sessions(excluding: { mode == .both && isDuplicate($0, knownSessionIds: known) }).first : nil
        let sessions = merge(herdr: herdr, local: localSession, mode: mode)
        return HerdSnapshot(
            sessions: sessions,
            counts: StatusCounts(agents: sessions.lazy.flatMap(\.workspaces).flatMap(\.agents)))
    }

    /// Session ids herdr already reports, for ``isDuplicate(_:knownSessionIds:)``.
    public static func knownSessionIds(_ herdr: [HerdSession]) -> Set<String> {
        Set(herdr.lazy.flatMap(\.workspaces).flatMap(\.agents).compactMap(\.agentSessionID))
    }

    /// A local agent herdr already shows: it runs under herdr, or herdr reports the same session id.
    public static func isDuplicate(_ agent: HerdAgent, knownSessionIds: Set<String>) -> Bool {
        agent.parentChainHasHerdr || (agent.agentSessionID.map(knownSessionIds.contains) ?? false)
    }

    /// A herdr session may itself be named like the local one; session names are the ids the UI keys on.
    static func localName(avoiding taken: [String], base: String) -> String {
        var name = base
        while taken.contains(name) { name += " (this Mac)" }
        return name
    }

    /// Session names for the settings roster. In any mode that includes local agents the local session's
    /// name is always offered, even while the filter hides it (a hidden local session is never scanned,
    /// so it would otherwise never reappear in the list that un-hides it).
    public static func rosterNames(_ sessions: [HerdSession], mode: AgentSourceMode) -> [String] {
        var names = sessions.map(\.name)
        guard mode != .herdr else { return names }
        // The local session is the one with no herdr socket.
        let herdrNames = sessions.filter { !$0.socketPath.isEmpty }.map(\.name)
        let local = localName(avoiding: herdrNames, base: LocalAgentSource.sessionName)
        if !names.contains(local) { names.append(local) }
        return names
    }

    private static func nonEmpty(_ session: HerdSession?) -> HerdSession? {
        guard let session, session.workspaces.contains(where: { !$0.agents.isEmpty }) else { return nil }
        return session
    }
}
