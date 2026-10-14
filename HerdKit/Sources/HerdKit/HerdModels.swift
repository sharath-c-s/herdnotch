import Foundation

// MARK: - Agent status

/// Lifecycle state of a coding agent as reported by herdr.
///
/// The five cases mirror the states herdr's `agent.list` emits today. `unknown` doubles as the
/// decoding fallback: herdr is free to add states in a future release, and a panel that throws on
/// an unrecognised string would render empty at exactly the moment the user needs it. Decoding an
/// unrecognised value therefore yields `unknown` rather than an error.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    /// The agent is waiting on the human: a permission prompt, a question, a confirmation.
    case blocked
    /// The agent has finished the work it was given and is reporting completion.
    ///
    /// Distinct from ``idle``, which is an agent that is merely quiet, and this build folded it to
    /// ``unknown`` until now: a finished agent showed as an orange question mark and the panel threw away
    /// its most accurate completion signal. The spelling comes from herdr's own serialisation, whose agent
    /// status variant list is `idle working blocked done unknown` in the shipped binary.
    ///
    /// Worth knowing when debugging: a `done` has never been captured on the wire here, only read out of
    /// the binary. If herdr ever spells it differently in a payload, ``init(from:)`` quietly returns
    /// ``unknown`` and the panel goes back to behaving as it did before, with nothing failing loudly.
    case done
    /// The agent is actively producing output.
    case working
    /// The agent is alive but has nothing in flight.
    case idle
    /// herdr could not determine a state, or reported a state this build does not recognise.
    case unknown

    /// Decodes a status string, mapping anything unrecognised to ``unknown``.
    ///
    /// - Parameter decoder: Decoder positioned at a single JSON string value.
    /// - Throws: Only if the underlying value is not a string at all. An unrecognised string never
    ///   throws, by design, so that a herdr upgrade cannot blank the panel.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Display ordering weight: lower sorts earlier in the panel.
    ///
    /// `blocked` first because it is the only state that needs the human, `done` next because a finished
    /// agent is news and a running one is not, `working` after that because it is the state the user is
    /// watching, then `unknown` (possibly interesting, possibly a bug) and finally `idle`, which is the
    /// bulk of rows and the least informative.
    public var sortRank: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .unknown: 3
        case .idle: 4
        }
    }

    /// Precedence weight used when collapsing several agents into one summary status.
    ///
    /// Deliberately different from ``sortRank``: for a roll-up, `idle` (a real, known state) beats
    /// `unknown`, whereas in the display order `unknown` is surfaced above the `idle` noise. `done`
    /// keeps the position it has in the display order, so a session holding one finished agent summarises
    /// as finished rather than as whatever its other agents are doing.
    private var rollUpRank: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }

    /// Combines two statuses into the one that should represent both.
    ///
    /// Precedence is `blocked` > `done` > `working` > `idle` > `unknown`. The operation is commutative,
    /// associative and idempotent, so it can be folded over any collection in any order to summarise
    /// a tab, a workspace or a whole session.
    ///
    /// - Parameter other: The status to combine with.
    /// - Returns: The higher-precedence of the two statuses.
    public func rollUp(_ other: AgentStatus) -> AgentStatus {
        rollUpRank <= other.rollUpRank ? self : other
    }
}

// MARK: - Tree nodes

/// Where an agent row came from: herdr's `agent.list`, or the local process scan.
public enum AgentOrigin: String, Codable, Sendable, Hashable {
    case herdr
    case local
}

/// One coding agent running in one herdr pane.
///
/// Field names mirror herdr's `agent.list` payload after snake_case conversion. `revision` is
/// present on the wire and intentionally dropped: it is an internal herdr sequence number with no
/// meaning to the panel.
public struct HerdAgent: Codable, Sendable, Identifiable, Hashable {
    /// A pane hosts at most one agent, so the pane id is a stable unique identity for SwiftUI.
    public var id: String { paneId }

    /// Agent kind as detected by herdr, for example `claude`, `codex`, `copilot`.
    public let agent: String
    /// Current lifecycle state.
    public let agentStatus: AgentStatus
    /// Working directory the pane was started in.
    public let cwd: String
    /// Directory of the pane's foreground process, which can differ from ``cwd`` after a `cd`.
    public let foregroundCwd: String?
    /// Whether this pane is the focused pane of its session.
    public let focused: Bool
    /// Pane identifier, for example `w1:p7`.
    public let paneId: String
    /// Identifier of the tab containing the pane, for example `w1:t7`.
    public let tabId: String
    /// Identifier of the workspace containing the tab, for example `w1`.
    public let workspaceId: String
    /// herdr's opaque terminal identifier. Absent for panes herdr cannot attribute to a terminal.
    public let terminalId: String?
    /// herdr's `agent_session` object. A malformed value decodes to an empty ref rather than throwing.
    private let agentSession: AgentSessionRef?

    private struct AgentSessionRef: Codable, Hashable, Sendable {
        let value: String?
        let source: String?

        init(value: String?, source: String?) {
            self.value = value
            self.source = source
        }

        private enum CodingKeys: String, CodingKey { case value, source }

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            value = try? c?.decodeIfPresent(String.self, forKey: .value)
            source = try? c?.decodeIfPresent(String.self, forKey: .source)
        }
    }

    /// Agent-side session id from `agent_session.value` (the Claude Code session UUID for claude).
    public var agentSessionID: String? { agentSession?.value }
    /// `agent_session.source`, for example `herdr:claude`. Gates which agents have a readable transcript.
    public var agentSessionSource: String? { agentSession?.source }

    /// User-visible label of the tab containing this pane, for example `catalog_version_diff`.
    ///
    /// Not part of the `agent.list` payload: it comes from a separate `tab.list` call that
    /// ``HerdSnapshotBuilder`` joins on ``tabId``. It is therefore `var` rather than `let`, and being
    /// `Optional` means the synthesised decoder uses `decodeIfPresent` and leaves it `nil` for raw
    /// `agent.list` bytes, so adding it cannot break the existing decode path or any fixture.
    ///
    /// `nil` whenever the join found no matching tab: `tab.list` failed for that session, or the tab
    /// appeared or vanished between the two round trips. Callers must be able to render without it.
    public var tabLabel: String?

    /// Stored as optionals so payloads without these keys (every herdr `agent.list` reply) keep decoding.
    private let origin: AgentOrigin?
    private let chainHasHerdr: Bool?

    /// Where this row came from. ``AgentOrigin/herdr`` for anything decoded from herdr.
    public var source: AgentOrigin { origin ?? .herdr }
    /// Process id of a ``AgentOrigin/local`` agent, `nil` for herdr agents.
    public let pid: Int32?
    /// Controlling tty device name (for example `ttys004`) of a local agent, `nil` when it has none.
    public let tty: String?
    /// Whether a local agent has a `herdr` process among its ancestors, so herdr already reports it.
    public var parentChainHasHerdr: Bool { chainHasHerdr ?? false }

    /// Memberwise initialiser, public so callers outside the module (and tests) can build fixtures.
    public init(
        agent: String,
        agentStatus: AgentStatus,
        cwd: String,
        foregroundCwd: String? = nil,
        focused: Bool = false,
        paneId: String,
        tabId: String,
        workspaceId: String,
        terminalId: String? = nil,
        agentSessionID: String? = nil,
        agentSessionSource: String? = nil,
        tabLabel: String? = nil,
        source: AgentOrigin = .herdr,
        pid: Int32? = nil,
        tty: String? = nil,
        parentChainHasHerdr: Bool = false
    ) {
        self.origin = source == .herdr ? nil : source
        self.pid = pid
        self.tty = tty
        self.chainHasHerdr = parentChainHasHerdr ? true : nil
        self.agent = agent
        self.agentStatus = agentStatus
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
        self.paneId = paneId
        self.tabId = tabId
        self.workspaceId = workspaceId
        self.terminalId = terminalId
        self.agentSession = (agentSessionID == nil && agentSessionSource == nil)
            ? nil : AgentSessionRef(value: agentSessionID, source: agentSessionSource)
        self.tabLabel = tabLabel
    }

    /// Display ordering for agents inside one workspace: by status, then by `cwd` alphabetically.
    ///
    /// Blocked agents surface at the top because acting on them is the entire point of the panel.
    /// The `cwd` tiebreak keeps row order stable across polls so the list does not shuffle under the
    /// cursor when two agents share a status.
    ///
    /// - Returns: `true` when `lhs` should appear before `rhs`.
    static func sortsBefore(_ lhs: HerdAgent, _ rhs: HerdAgent) -> Bool {
        if lhs.agentStatus.sortRank != rhs.agentStatus.sortRank {
            return lhs.agentStatus.sortRank < rhs.agentStatus.sortRank
        }
        if lhs.cwd != rhs.cwd { return lhs.cwd < rhs.cwd }
        return lhs.paneId < rhs.paneId
    }
}

/// One herdr workspace with the agents found inside it.
///
/// Everything except ``agents`` comes straight from `workspace.list`. ``agents`` is filled in by
/// ``HerdSnapshotBuilder`` from a separate `agent.list` call, so it decodes to an empty array when
/// absent, which is what raw herdr payloads look like.
public struct HerdWorkspace: Codable, Sendable, Identifiable, Hashable {
    /// Workspace ids are unique within a session, which is the only scope this type is rendered in.
    public var id: String { workspaceId }

    /// Workspace identifier, for example `w1`.
    public let workspaceId: String
    /// User-visible workspace name, for example `shara_misc`. Absent for unnamed workspaces.
    public let label: String?
    /// One-based workspace number used for ordering. Absent for synthesised workspaces.
    public let number: Int?
    /// Whether this is the session's focused workspace.
    public let focused: Bool
    /// herdr's own roll-up of the workspace's agent states.
    public let agentStatus: AgentStatus
    /// Number of panes herdr reports in the workspace, including panes with no agent.
    public let paneCount: Int?
    /// Number of tabs herdr reports in the workspace.
    public let tabCount: Int?
    /// Identifier of the workspace's active tab.
    public let activeTabId: String?
    /// Agents in this workspace, pre-sorted by ``HerdSnapshotBuilder``.
    public var agents: [HerdAgent]

    /// Memberwise initialiser, public so callers outside the module (and tests) can build fixtures.
    public init(
        workspaceId: String,
        label: String? = nil,
        number: Int? = nil,
        focused: Bool = false,
        agentStatus: AgentStatus,
        paneCount: Int? = nil,
        tabCount: Int? = nil,
        activeTabId: String? = nil,
        agents: [HerdAgent] = []
    ) {
        self.workspaceId = workspaceId
        self.label = label
        self.number = number
        self.focused = focused
        self.agentStatus = agentStatus
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.activeTabId = activeTabId
        self.agents = agents
    }

    /// Decodes a workspace, tolerating the missing `agents` key that raw `workspace.list` payloads
    /// have. Without this the same type could not be used for both wire decoding and the assembled
    /// snapshot, and the app would need two parallel model hierarchies.
    ///
    /// - Parameter decoder: Decoder positioned at a workspace object.
    /// - Throws: `DecodingError` if a required key is missing or mistyped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try c.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        paneCount = try c.decodeIfPresent(Int.self, forKey: .paneCount)
        tabCount = try c.decodeIfPresent(Int.self, forKey: .tabCount)
        activeTabId = try c.decodeIfPresent(String.self, forKey: .activeTabId)
        agents = try c.decodeIfPresent([HerdAgent].self, forKey: .agents) ?? []
    }

    /// Display ordering for workspaces inside one session: by ``number`` ascending, unnumbered last.
    ///
    /// Unnumbered workspaces are only ever synthesised placeholders (see
    /// ``HerdSnapshotBuilder``), so parking them at the end keeps the real, numbered workspaces in
    /// the order the user sees them in herdr.
    ///
    /// - Returns: `true` when `lhs` should appear before `rhs`.
    static func sortsBefore(_ lhs: HerdWorkspace, _ rhs: HerdWorkspace) -> Bool {
        switch (lhs.number, rhs.number) {
        case let (l?, r?): return l == r ? lhs.workspaceId < rhs.workspaceId : l < r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return lhs.workspaceId < rhs.workspaceId
        }
    }
}

/// One herdr session: the default session or a named one under `~/.config/herdr/sessions/`.
///
/// Stopped sessions are represented, not omitted. A session that vanishes from the panel when its
/// server stops is worse than one that shows as stopped, because the user cannot tell the
/// difference between "stopped" and "the panel is broken".
public struct HerdSession: Codable, Sendable, Identifiable, Hashable {
    /// Session names are unique per config root, which is the only scope in play.
    public var id: String { name }

    /// Session name. The default session is named `default`.
    public let name: String
    /// Whether this is herdr's default session, whose socket sits directly in the config root.
    public let isDefault: Bool
    /// Whether this session was found through a configured extra socket path rather than under
    /// `~/.config/herdr`.
    ///
    /// "Remote" is a statement about how the socket was reached, not about a different protocol. herdr's
    /// `--remote <ssh-target>` is an *attach* mechanism: it bridges a local client over SSH to a herdr
    /// server on the far host, so the session's socket lives on that host and never appears in the local
    /// config root. `ssh -L /local/path:/remote/path` puts an equivalent endpoint at a local path, and
    /// from there every existing call works unchanged, which is why this is a display flag rather than a
    /// second code path.
    ///
    /// It exists because the difference matters to the user in two ways the panel has to state: a remote
    /// session's terminal is on another machine, so no window can be brought forward for it, and a remote
    /// session's failures are as likely to be the tunnel as the server.
    public let isRemote: Bool
    /// Whether a `connect()` to ``socketPath`` succeeded. This is exactly how the herdr CLI decides
    /// liveness, so the panel and the CLI can never disagree.
    public let running: Bool
    /// Absolute path of the session's `herdr.sock`.
    public let socketPath: String
    /// Workspaces in the session, pre-sorted. Always empty for a stopped session.
    public var workspaces: [HerdWorkspace]
    /// Message describing why this session's data could not be fetched, `nil` on success.
    ///
    /// Scoped per session on purpose: one unresponsive session must degrade to a single error row,
    /// never take the whole snapshot down.
    public let error: String?

    /// The name herdr uses for the session whose socket lives directly in the config root.
    public static let defaultSessionName = "default"

    /// Memberwise initialiser, public so callers outside the module (and tests) can build fixtures.
    public init(
        name: String,
        isDefault: Bool,
        running: Bool,
        socketPath: String,
        isRemote: Bool = false,
        workspaces: [HerdWorkspace] = [],
        error: String? = nil
    ) {
        self.name = name
        self.isDefault = isDefault
        self.isRemote = isRemote
        self.running = running
        self.socketPath = socketPath
        self.workspaces = workspaces
        self.error = error
    }

    /// Decodes a session, defaulting ``workspaces`` to empty when the key is absent.
    ///
    /// - Parameter decoder: Decoder positioned at a session object.
    /// - Throws: `DecodingError` if a required key is missing or mistyped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        // Absent in payloads written before remote sessions existed, and absent from herdr's own wire
        // shapes, which have no concept of it. Defaulting to `false` keeps every stored snapshot and every
        // fixture decodable.
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        running = try c.decode(Bool.self, forKey: .running)
        socketPath = try c.decode(String.self, forKey: .socketPath)
        workspaces = try c.decodeIfPresent([HerdWorkspace].self, forKey: .workspaces) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    /// Display ordering for sessions: running first, local before remote, the default session first
    /// within its group, then by name.
    ///
    /// Running-first because stopped sessions are context, not content. Local-before-remote because a
    /// remote session is somebody else's machine and cannot be switched to, so it is context in the same
    /// way a stopped session is. Default-first because it is the session the user is in when they have not
    /// thought about sessions at all.
    ///
    /// This is *discovery* order, not final display order. The model re-sorts by urgency afterwards through
    /// `HerdUrgencyOrder`, and urgency wins: a remote session with a blocked agent outranks a local session
    /// where nothing is happening, which is correct and means the remote rows do not always sit in one
    /// block. What this ordering settles is the tie-break, which on the all-idle day is every comparison.
    ///
    /// - Returns: `true` when `lhs` should appear before `rhs`.
    static func sortsBefore(_ lhs: HerdSession, _ rhs: HerdSession) -> Bool {
        if lhs.running != rhs.running { return lhs.running }
        if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
        return lhs.name < rhs.name
    }
}

// MARK: - Roll-up

/// Number of agents in each status across a whole snapshot.
///
/// Precomputed during snapshot assembly so the collapsed-notch indicator can render from five
/// integers without walking the session tree on every frame.
public struct StatusCounts: Codable, Sendable, Hashable {
    /// Agents waiting on the human.
    public let blocked: Int
    /// Agents reporting that they have finished.
    public let done: Int
    /// Agents actively producing output.
    public let working: Int
    /// Agents alive with nothing in flight.
    public let idle: Int
    /// Agents whose state herdr did not report, or reported as a value this build predates.
    public let unknown: Int

    /// Memberwise initialiser, public so callers outside the module (and tests) can build fixtures.
    public init(blocked: Int = 0, done: Int = 0, working: Int = 0, idle: Int = 0, unknown: Int = 0) {
        self.blocked = blocked
        self.done = done
        self.working = working
        self.idle = idle
        self.unknown = unknown
    }

    /// Decodes a tally, defaulting every field that is absent to zero.
    ///
    /// Written out rather than synthesised specifically so ``done`` could be added without invalidating
    /// data already on disk. The synthesised decoder over non-optional `let`s throws on a missing key, so
    /// adding a field to this type would have made every snapshot encoded by an earlier build, and every
    /// stored fixture, undecodable. Defaulting to zero is also the honest answer: a payload written before
    /// `done` existed genuinely counted none.
    ///
    /// - Parameter decoder: Decoder positioned at a counts object.
    /// - Throws: `DecodingError` only if a present value is not an integer.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocked = try c.decodeIfPresent(Int.self, forKey: .blocked) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        working = try c.decodeIfPresent(Int.self, forKey: .working) ?? 0
        idle = try c.decodeIfPresent(Int.self, forKey: .idle) ?? 0
        unknown = try c.decodeIfPresent(Int.self, forKey: .unknown) ?? 0
    }

    /// Tallies a flat collection of agents by status.
    ///
    /// - Parameter agents: Agents to count, from any number of sessions.
    public init(agents: some Sequence<HerdAgent>) {
        var tally: [AgentStatus: Int] = [:]
        for agent in agents { tally[agent.agentStatus, default: 0] += 1 }
        self.init(
            blocked: tally[.blocked] ?? 0,
            done: tally[.done] ?? 0,
            working: tally[.working] ?? 0,
            idle: tally[.idle] ?? 0,
            unknown: tally[.unknown] ?? 0
        )
    }

    /// Total number of agents counted.
    public var total: Int { blocked + done + working + idle + unknown }
}

/// A complete view of every herdr session at one instant.
///
/// This is the single value that crosses the XPC boundary, JSON-encoded with ``HerdJSON/encoder``.
/// Everything in it is already sorted and pre-aggregated, so the UI renders it as-is.
public struct HerdSnapshot: Codable, Sendable {
    /// All discovered sessions, running before stopped, default first, then by name.
    public let sessions: [HerdSession]
    /// Status tally across every agent in every session.
    public let counts: StatusCounts

    /// Memberwise initialiser, public so callers outside the module (and tests) can build fixtures.
    public init(sessions: [HerdSession], counts: StatusCounts) {
        self.sessions = sessions
        self.counts = counts
    }
}

// MARK: - Coders

/// The one pair of JSON coders used everywhere HerdKit data is serialised.
///
/// Both directions use the same key strategy, `convertFromSnakeCase` / `convertToSnakeCase`, so a
/// value encoded here always round-trips: herdr's wire format and HerdKit's own XPC payloads share
/// one convention and there is no second strategy to get wrong. Consumers must use these rather
/// than building their own coder, otherwise `agentStatus` and `agent_status` drift apart.
public enum HerdJSON {
    /// Shared decoder for herdr wire payloads and HerdKit's own snapshots.
    ///
    /// Thread-safety: `JSONDecoder` is safe for concurrent decoding as long as it is not
    /// reconfigured, and this instance is configured once here and never mutated afterwards.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Shared encoder for HerdKit snapshots and herdr requests.
    ///
    /// Thread-safety: as with ``decoder``, configured once and never mutated.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
