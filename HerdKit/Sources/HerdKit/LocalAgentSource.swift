import Foundation

/// Live Claude and Codex agents found without herdr, as one session named ``sessionName``.
///
/// Claude comes from the session registry, verified against the process table. Codex comes from a
/// process scan, with each process mapped to its rollout through its open file descriptors, else through
/// the single recent rollout whose `session_meta.cwd` matches the process cwd.
///
/// Local agents use synthetic ids `local:<pid>` for pane, tab and agent-level workspace. The workspace
/// that contains them is keyed by project root path, so an agent's ``HerdAgent/workspaceId`` does not
/// match its container's id; nothing in HerdKit joins on it.
public struct LocalAgentSource: AgentSource {
    public static let sessionName = "local"

    private let registry: ClaudeSessionRegistry
    private let processes: any ProcessInspecting
    private let codexRoot: URL
    private let codexTracker: CodexRolloutTracker
    private let isGitRoot: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    /// Pending permission or question text for a Claude session id, `nil` when none. A non-nil answer for
    /// a non-busy agent makes it `blocked`.
    ///
    /// Integration hook: ``TranscriptReader`` is a stateful, non-thread-safe tail reader, so the owner
    /// keeps one per session id (resolved with ``TranscriptLocator``) and returns `read().pendingAsk`.
    /// Wiring it here would hide that state inside a value type.
    private let pendingAsk: @Sendable (String) -> String?

    public init(
        registry: ClaudeSessionRegistry? = nil,
        processes: (any ProcessInspecting)? = nil,
        codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        codexTracker: CodexRolloutTracker = CodexRolloutTracker(),
        isGitRoot: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") },
        now: @escaping @Sendable () -> Date = { Date() },
        pendingAsk: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        // One inspector feeds both, so its caches are not duplicated.
        let inspector = processes ?? DarwinProcessInspector()
        self.registry = registry ?? ClaudeSessionRegistry(processes: inspector)
        self.processes = inspector
        self.codexRoot = codexRoot
        self.codexTracker = codexTracker
        self.isGitRoot = isGitRoot
        self.now = now
        self.pendingAsk = pendingAsk
    }

    /// One `local` session, or `[]` when no live local agent exists.
    public func sessions() -> [HerdSession] { sessions(excluding: { _ in false }) }

    /// Like ``sessions()``, but agents matching `excluded` are dropped before any transcript read or
    /// grouping, so no work is spent on agents ``AgentSourceMerge`` would discard anyway
    /// (see ``AgentSourceMerge/isDuplicate(_:knownSessionIds:)``).
    ///
    /// - Parameter entries: Live registry entries already read this poll, to avoid a second read.
    public func sessions(excluding excluded: (HerdAgent) -> Bool, entries: [ClaudeRegistryEntry]? = nil) -> [HerdSession] {
        let agents = claudeAgents(excluding: excluded, entries: entries) + codexAgents().filter { !excluded($0) }
        guard !agents.isEmpty else { return [] }
        return [HerdSession(
            name: Self.sessionName, isDefault: false, running: true, socketPath: "",
            workspaces: Self.group(agents, isGitRoot: isGitRoot)
        )]
    }

    // MARK: - Claude

    /// One registry read, shared with the herdr name join in ``AgentSourceMerge/snapshot``.
    public func liveClaudeEntries() -> [ClaudeRegistryEntry] { registry.liveEntries() }

    func claudeAgents(
        excluding excluded: (HerdAgent) -> Bool = { _ in false }, entries: [ClaudeRegistryEntry]? = nil
    ) -> [HerdAgent] {
        (entries ?? registry.liveEntries()).compactMap { entry in
            let tty = processes.tty(of: entry.pid)
            let chain = processes.parentChainHasHerdr(of: entry.pid)
            func make(_ status: AgentStatus) -> HerdAgent {
                HerdAgent(
                    agent: "claude", agentStatus: status, cwd: entry.cwd,
                    paneId: "local:\(entry.pid)", tabId: "local:\(entry.pid)", workspaceId: "local:\(entry.pid)",
                    agentSessionID: entry.sessionId, agentSessionSource: "local:claude",
                    claudeSessionName: entry.name.isEmpty ? nil : entry.name,
                    claudeSessionNameSource: entry.name.isEmpty ? nil : entry.nameSource,
                    source: .local, pid: entry.pid, tty: tty, parentChainHasHerdr: chain
                )
            }
            // The transcript read is the costly part, so it only happens for agents that survive `excluded`.
            let base = make(Self.registryStatus(entry.status))
            if excluded(base) { return nil }
            let askable = base.agentStatus == .idle || base.agentStatus == .unknown
            return askable && pendingAsk(entry.sessionId) != nil ? make(.blocked) : base
        }
    }

    /// `waiting` is observed live and means the agent needs the user, so it needs no transcript read.
    private static func registryStatus(_ raw: String) -> AgentStatus {
        switch raw {
        case "busy": return .working
        case "idle": return .idle
        case "waiting": return .blocked
        default: return .unknown
        }
    }

    // MARK: - Codex

    func codexAgents() -> [HerdAgent] {
        let candidates = processes.allPids().filter(isCodex)
        // No codex process: skip fd and rollout scanning, and drop every cursor.
        guard !candidates.isEmpty else {
            codexTracker.retain([])
            return []
        }
        let set = Set(candidates)
        // A node wrapper spawns the real binary; keep the outermost so one agent is not listed twice.
        let roots = candidates.filter { pid in !(processes.parentPid(of: pid).map(set.contains) ?? false) }
        // The npm wrapper is the root but its native child holds the rollout fd: ask the root, then each
        // folded child, first hit wins.
        let rootSet = Set(roots)
        var folded: [Int32: [Int32]] = [:]
        for pid in candidates.sorted() where !rootSet.contains(pid) {
            if let root = rootAncestor(of: pid, in: rootSet) { folded[root, default: []].append(pid) }
        }
        let opened = Dictionary(uniqueKeysWithValues: roots.compactMap { pid in
            ([pid] + (folded[pid] ?? [])).lazy.compactMap { processes.openRolloutPath(of: $0) }.first
                .map { (pid, URL(fileURLWithPath: $0)) }
        })
        let claimed = Set(opened.values)
        // Built lazily: the directory scan is only worth doing when some process has no open rollout.
        let recent = roots.contains { opened[$0] == nil }
            ? CodexRolloutReader.recentRollouts(root: codexRoot, now: now()) : []

        codexTracker.retain(Set(opened.values).union(recent))
        return roots.sorted().compactMap { pid in
            guard let cwd = processes.cwd(of: pid) else { return nil }
            let rollout = opened[pid] ?? uniqueMatch(
                cwd: cwd, in: recent.filter { !claimed.contains($0) })
            let status = rollout.map { codexTracker.state(of: $0).status } ?? .unknown
            return HerdAgent(
                agent: "codex", agentStatus: status, cwd: cwd,
                paneId: "local:\(pid)", tabId: "local:\(pid)", workspaceId: "local:\(pid)",
                tabLabel: (cwd as NSString).lastPathComponent,
                source: .local, pid: pid, tty: processes.tty(of: pid),
                parentChainHasHerdr: processes.parentChainHasHerdr(of: pid)
            )
        }
    }

    private func rootAncestor(of pid: Int32, in roots: Set<Int32>) -> Int32? {
        var current = processes.parentPid(of: pid)
        var hops = 0
        while let p = current, hops < 64 {
            if roots.contains(p) { return p }
            current = processes.parentPid(of: p)
            hops += 1
        }
        return nil
    }

    private func isCodex(_ pid: Int32) -> Bool {
        guard let name = processes.name(of: pid) else { return false }
        if name == "codex" { return true }
        guard name == "node", let argv = processes.argv(of: pid) else { return false }
        return argv.prefix(2).contains { ($0 as NSString).lastPathComponent == "codex" }
    }

    /// The rollout whose cwd equals `cwd`, only when exactly one does.
    private func uniqueMatch(cwd: String, in rollouts: [URL]) -> URL? {
        let matches = rollouts.filter { codexTracker.cwd(of: $0) == cwd }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Grouping

    /// Project root of `cwd`: the nearest ancestor (or itself) that is a git root, else `cwd`.
    public static func projectRoot(of cwd: String, isGitRoot: (String) -> Bool) -> String {
        var path = cwd
        while path.count > 1 {
            if isGitRoot(path) { return path }
            path = (path as NSString).deletingLastPathComponent
        }
        return cwd
    }

    public static func group(_ agents: [HerdAgent], isGitRoot: (String) -> Bool) -> [HerdWorkspace] {
        // Agents often share a repo, so each directory's `.git` stat is done once per call.
        var gitRoots: [String: Bool] = [:]
        func cachedIsGitRoot(_ path: String) -> Bool {
            if let known = gitRoots[path] { return known }
            let result = isGitRoot(path)
            gitRoots[path] = result
            return result
        }
        let byRoot = Dictionary(grouping: agents) { projectRoot(of: $0.cwd, isGitRoot: cachedIsGitRoot) }
        return byRoot.map { root, members in
            let sorted = members.sorted(by: HerdAgent.sortsBefore)
            return HerdWorkspace(
                workspaceId: root,
                label: (root as NSString).lastPathComponent,
                agentStatus: sorted.map(\.agentStatus).reduce(AgentStatus.unknown) { $0.rollUp($1) },
                agents: sorted
            )
        }.sorted(by: HerdWorkspace.sortsBefore)
    }
}
