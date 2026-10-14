import Foundation
@testable import HerdKit
import Testing

/// Process table fake. Dictionary-driven so each test states exactly the processes that exist.
private struct FakeProcs: ProcessInspecting {
    struct P {
        var name = "x"
        var start: Int64 = 1000
        var ppid: Int32 = 1
        var cwd: String? = nil
        var tty: String? = nil
        var argv: [String]? = nil
        var rollout: String? = nil
        var alive = true
    }
    var procs: [Int32: P] = [:]

    func allPids() -> [Int32] { Array(procs.keys) }
    func isAlive(_ pid: Int32) -> Bool { procs[pid]?.alive ?? false }
    func startTime(of pid: Int32) -> Int64? { procs[pid]?.start }
    func name(of pid: Int32) -> String? { procs[pid]?.name }
    func argv(of pid: Int32) -> [String]? { procs[pid]?.argv }
    func parentPid(of pid: Int32) -> Int32? { procs[pid]?.ppid }
    func cwd(of pid: Int32) -> String? { procs[pid]?.cwd }
    func tty(of pid: Int32) -> String? { procs[pid]?.tty }
    func openRolloutPath(of pid: Int32) -> String? { procs[pid]?.rollout }
}

/// Process table whose contents a test changes between calls.
private final class MutableProcs: ProcessInspecting, @unchecked Sendable {
    var procs: [Int32: FakeProcs.P]
    init(_ procs: [Int32: FakeProcs.P]) { self.procs = procs }
    func allPids() -> [Int32] { Array(procs.keys) }
    func isAlive(_ pid: Int32) -> Bool { procs[pid] != nil }
    func startTime(of pid: Int32) -> Int64? { procs[pid]?.start }
    func name(of pid: Int32) -> String? { procs[pid]?.name }
    func argv(of pid: Int32) -> [String]? { procs[pid]?.argv }
    func parentPid(of pid: Int32) -> Int32? { procs[pid]?.ppid }
    func cwd(of pid: Int32) -> String? { procs[pid]?.cwd }
    func tty(of pid: Int32) -> String? { procs[pid]?.tty }
    func openRolloutPath(of pid: Int32) -> String? { procs[pid]?.rollout }
}

struct LocalAgentSourceTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let procStartText = "Tue Oct 13 12:33:29 2026"
    private static var procStartEpoch: Int64 { ClaudeSessionRegistry.parseProcStart(procStartText)! }

    private func writeEntry(_ dir: URL, pid: Int32, sessionId: String = "sess", cwd: String = "/p/a",
        status: String = "idle", name: String = "nm", procStart: String = LocalAgentSourceTests.procStartText) throws
    {
        let obj: [String: Any] = ["pid": pid, "sessionId": sessionId, "cwd": cwd, "status": status,
            "name": name, "procStart": procStart]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("\(pid).json"))
    }

    private func event(_ type: String) -> String {
        #"{"timestamp":"2026-10-13T10:49:18.634Z","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func agent(_ pid: Int32, _ cwd: String, status: AgentStatus = .idle, session: String? = nil,
        herdrParent: Bool = false) -> HerdAgent
    {
        HerdAgent(agent: "claude", agentStatus: status, cwd: cwd, paneId: "local:\(pid)", tabId: "local:\(pid)",
            workspaceId: "local:\(pid)", agentSessionID: session, source: .local, pid: pid,
            parentChainHasHerdr: herdrParent)
    }

    private func session(_ name: String, _ agents: [HerdAgent], local: Bool = false) -> HerdSession {
        HerdSession(name: name, isDefault: false, running: true, socketPath: local ? "" : "/s",
            workspaces: [HerdWorkspace(workspaceId: "w", agentStatus: .idle, agents: agents)])
    }

    // MARK: - Registry

    @Test func procStartParsesCtimeInGivenZone() {
        let utc = TimeZone(identifier: "UTC")!
        let parsed = ClaudeSessionRegistry.parseProcStart("Tue Oct 13 12:33:29 2026", timeZone: utc)
        let expected = ISO8601DateFormatter().date(from: "2026-10-13T12:33:29Z")!.timeIntervalSince1970
        #expect(parsed == Int64(expected))
        #expect(ClaudeSessionRegistry.parseProcStart("Sun Oct  4 01:02:03 2026", timeZone: utc) != nil)
        #expect(ClaudeSessionRegistry.parseProcStart("garbage") == nil)
    }

    @Test func procStartIsUTCEvenWhenLocalZoneDiffers() throws {
        // 1791894809 was computed with `TZ=UTC date -j -f ... +%s`, independent of parseProcStart, and is the
        // kernel start time of pid 10406 on the machine that wrote this string.
        #expect(ClaudeSessionRegistry.parseProcStart(Self.procStartText) == 1_791_894_809)
        let dir = try tempDir()
        try writeEntry(dir, pid: 10406, sessionId: "real")
        let procs = FakeProcs(procs: [10406: .init(start: 1_791_894_809)])
        #expect(ClaudeSessionRegistry(directory: dir, processes: procs).liveEntries().map(\.sessionId) == ["real"])
    }

    @Test func registryKeepsLiveAndSkipsStaleAndKeyFiles() throws {
        let dir = try tempDir()
        let start = Self.procStartEpoch
        try writeEntry(dir, pid: 10, sessionId: "live")
        try writeEntry(dir, pid: 11, sessionId: "reused")       // start time differs: pid was reused
        try writeEntry(dir, pid: 12, sessionId: "dead")         // not in process table
        try writeEntry(dir, pid: 13, sessionId: "within-tol")   // +2 s is allowed
        try writeEntry(dir, pid: 14, sessionId: "outside-tol")  // +3 s is not
        try writeEntry(dir, pid: 15, sessionId: "bad-start", procStart: "nonsense")
        try Data("secret".utf8).write(to: dir.appendingPathComponent("10.abc.key"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("99.json"))
        let procs = FakeProcs(procs: [
            10: .init(start: start), 11: .init(start: start + 500), 13: .init(start: start + 2),
            14: .init(start: start + 3), 15: .init(start: start),
        ])
        let live = ClaudeSessionRegistry(directory: dir, processes: procs).liveEntries()
        #expect(live.map(\.sessionId) == ["live", "within-tol"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("12.json").path))
    }

    @Test func registryTreatsEPERMAsAlive() throws {
        // The fake's isAlive models kill(pid, 0) == -1 with errno EPERM as true; the real inspector does the same.
        let dir = try tempDir()
        try writeEntry(dir, pid: 20, sessionId: "other-user")
        let procs = FakeProcs(procs: [20: .init(start: Self.procStartEpoch, alive: true)])
        #expect(ClaudeSessionRegistry(directory: dir, processes: procs).liveEntries().count == 1)
    }

    @Test func darwinInspectorAnswersForSelfAndRejectsGonePid() {
        let inspector = DarwinProcessInspector()
        let me = getpid()
        #expect(inspector.isAlive(me))
        #expect(inspector.startTime(of: me) != nil)
        #expect(inspector.name(of: me) != nil)
        #expect(inspector.cwd(of: me) != nil)
        #expect(inspector.allPids().contains(me))
        // The answer depends on whether this run is itself under herdr, so only agreement is asserted.
        #expect(inspector.parentChainHasHerdr(of: me) == inspector.parentChainHasHerdr(of: me))
        #expect(inspector.startTime(of: 2_000_000_000) == nil)
        #expect(!inspector.isAlive(2_000_000_000))
    }

    // MARK: - Claude agents

    @Test func claudeAgentMapsRegistryFields() throws {
        let dir = try tempDir()
        try writeEntry(dir, pid: 30, sessionId: "abc", cwd: "/p/a", status: "busy", name: "my-agent")
        try writeEntry(dir, pid: 31, sessionId: "def", cwd: "/p/a", status: "shell")
        try writeEntry(dir, pid: 32, sessionId: "ghi", cwd: "/p/a", status: "idle")
        let start = Self.procStartEpoch
        let procs = FakeProcs(procs: [
            30: .init(start: start, ppid: 5, tty: "ttys004"), 31: .init(start: start), 32: .init(start: start),
            5: .init(name: "herdr"),
        ])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: dir, processes: procs), processes: procs,
            codexRoot: try tempDir(), isGitRoot: { _ in false },
            pendingAsk: { $0 == "ghi" ? "wants to run: ls" : nil })
        let agents = source.sessions().flatMap(\.workspaces).flatMap(\.agents)
        let byPid = Dictionary(uniqueKeysWithValues: agents.map { ($0.pid!, $0) })
        let busy = try #require(byPid[30])
        #expect(busy.agentStatus == .working)
        #expect(busy.paneId == "local:30" && busy.tabId == "local:30" && busy.workspaceId == "local:30")
        #expect(busy.agentSessionID == "abc" && busy.tabLabel == "my-agent" && busy.tty == "ttys004")
        #expect(busy.source == .local && busy.parentChainHasHerdr)
        #expect(byPid[31]?.agentStatus == .unknown)
        #expect(byPid[32]?.agentStatus == .blocked)
        #expect(byPid[32]?.parentChainHasHerdr == false)
    }

    @Test func busyAgentIsNotBlockedByStalePendingAsk() throws {
        let dir = try tempDir()
        try writeEntry(dir, pid: 40, status: "busy")
        let procs = FakeProcs(procs: [40: .init(start: Self.procStartEpoch)])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: dir, processes: procs), processes: procs,
            codexRoot: try tempDir(), isGitRoot: { _ in false }, pendingAsk: { _ in "ask" })
        #expect(source.sessions().first?.workspaces.first?.agents.first?.agentStatus == .working)
    }

    @Test func noLiveAgentsYieldsNoSession() throws {
        let procs = FakeProcs()
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: try tempDir(), processes: procs), processes: procs,
            codexRoot: try tempDir())
        #expect(source.sessions().isEmpty)
    }

    @Test func herdrAncestorExitingFlipsParentChainOnNextCall() throws {
        let dir = try tempDir()
        try writeEntry(dir, pid: 80, status: "idle")
        let procs = MutableProcs([80: .init(start: Self.procStartEpoch, ppid: 5), 5: .init(name: "herdr")])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: dir, processes: procs), processes: procs,
            codexRoot: try tempDir(), isGitRoot: { _ in false })
        func chain() -> Bool? { source.sessions().first?.workspaces.first?.agents.first?.parentChainHasHerdr }
        #expect(chain() == true)
        procs.procs[5] = nil
        procs.procs[80]?.ppid = 1   // reparented to launchd
        #expect(chain() == false)
    }

    // MARK: - Codex rollout parsing

    @Test func codexTailStates() throws {
        let dir = try tempDir()
        func status(_ lines: [String]) throws -> AgentStatus {
            let url = dir.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
            return CodexRolloutTracker().state(of: url).status
        }
        #expect(try status([event("task_started"), event("token_count")]) == .working)
        #expect(try status([event("task_started"), event("task_complete")]) == .idle)
        #expect(try status([event("task_complete"), event("task_started")]) == .working)
        #expect(try status([event("task_started"), event("turn_aborted")]) == .idle)
        #expect(try status([event("task_started"), event("exec_approval_request")]) == .blocked)
        #expect(try status([event("task_started"), event("exec_approval_request"), event("exec_command_end")]) == .working)
        #expect(try status([event("item_completed"), "not json"]) == .unknown)
        #expect(try status([]) == .unknown)
    }

    @Test func codexReadsOnlyBoundedTailAndDropsPartialLine() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("rollout-x.jsonl")
        // Old completed turn, then more than the tail window of noise, then a started turn.
        let noise = String(repeating: event("token_count") + "\n", count: 6000)
        let text = event("task_started") + "\n" + event("task_complete") + "\n" + noise + event("task_started") + "\n"
        // An unterminated trailing line is half-written: it must not be folded.
        let partial = #"{"type":"event_msg","payload":{"type":"task_complete""#
        try Data((text + partial).utf8).write(to: url)
        #expect(text.utf8.count > 256 * 1024)
        let tracker = CodexRolloutTracker()
        #expect(tracker.state(of: url).status == .working)
        #expect(tracker.bytesRead <= CodexRolloutReader.tailBytes)
        #expect(tracker.state(of: dir.appendingPathComponent("missing.jsonl")).status == .unknown)
    }

    @Test func codexSessionCwdFromHead() {
        let head = #"{"type":"session_meta","payload":{"id":"i","timestamp":"t","cwd":"/a/b \"q\"","originator":"x"#
        #expect(CodexRolloutReader.sessionCwd(fromHead: head) == #"/a/b "q""#)
        #expect(CodexRolloutReader.sessionCwd(fromHead: "{}") == nil)
    }

    // MARK: - Codex discovery

    private func writeRollout(_ root: URL, name: String, cwd: String, events: [String], now: Date) throws -> URL {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: now)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(name).jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"\#(name)","cwd":"\#(cwd)"}}"#
        try Data(([meta] + events).joined(separator: "\n").appending("\n").utf8).write(to: url)
        return url
    }

    @Test func codexUsesOpenFdRolloutAndFoldsNodeWrapper() throws {
        let root = try tempDir()
        let now = Date()
        let url = try writeRollout(root, name: "a", cwd: "/p/x", events: [event("task_started")], now: now)
        let procs = FakeProcs(procs: [
            50: .init(name: "node", ppid: 9, cwd: "/p/x", tty: "ttys001", argv: ["node", "/usr/bin/codex"],
                rollout: url.path),
            51: .init(name: "codex", ppid: 50, cwd: "/p/x", rollout: url.path),  // child of the wrapper
            60: .init(name: "node", cwd: "/p/y", argv: ["node", "/srv/app.js"]),  // not codex
        ])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: try tempDir(), processes: procs), processes: procs,
            codexRoot: root, isGitRoot: { _ in false }, now: { now })
        let agents = source.sessions().flatMap(\.workspaces).flatMap(\.agents)
        #expect(agents.count == 1)
        #expect(agents[0].agent == "codex" && agents[0].pid == 50)
        #expect(agents[0].agentStatus == .working && agents[0].tty == "ttys001")
        #expect(agents[0].tabLabel == "x")
    }

    @Test func codexWrapperTakesRolloutHeldOnlyByChild() throws {
        let root = try tempDir()
        let now = Date()
        let url = try writeRollout(root, name: "c", cwd: "/p/x", events: [event("task_started")], now: now)
        let procs = FakeProcs(procs: [
            50: .init(name: "node", ppid: 9, cwd: "/p/x", argv: ["node", "/usr/bin/codex"]),   // no fd
            51: .init(name: "codex", ppid: 50, cwd: "/p/x", rollout: url.path),
        ])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: try tempDir(), processes: procs), processes: procs,
            codexRoot: root, isGitRoot: { _ in false }, now: { now })
        let agents = source.sessions().flatMap(\.workspaces).flatMap(\.agents)
        #expect(agents.map(\.pid) == [50])
        #expect(agents[0].agentStatus == .working)
    }

    @Test func codexFallbackNeedsExactlyOneCwdMatch() throws {
        let root = try tempDir()
        let now = Date()
        _ = try writeRollout(root, name: "one", cwd: "/p/solo", events: [event("task_complete")], now: now)
        _ = try writeRollout(root, name: "two-a", cwd: "/p/dup", events: [event("task_started")], now: now)
        _ = try writeRollout(root, name: "two-b", cwd: "/p/dup", events: [event("task_started")], now: now)
        let procs = FakeProcs(procs: [
            70: .init(name: "codex", cwd: "/p/solo"), 71: .init(name: "codex", cwd: "/p/dup"),
            72: .init(name: "codex", cwd: "/p/none"),
        ])
        let source = LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: try tempDir(), processes: procs), processes: procs,
            codexRoot: root, isGitRoot: { _ in false }, now: { now })
        let byPid = Dictionary(uniqueKeysWithValues:
            source.sessions().flatMap(\.workspaces).flatMap(\.agents).map { ($0.pid!, $0.agentStatus) })
        #expect(byPid[70] == .idle)
        #expect(byPid[71] == .unknown)
        #expect(byPid[72] == .unknown)
    }

    // MARK: - Grouping

    @Test func workspacesGroupByGitRootElseCwd() throws {
        let agents = [
            agent(1, "/repo/app/sub", status: .working), agent(2, "/repo/app", status: .idle),
            agent(3, "/loose/dir"),
        ]
        let groups = LocalAgentSource.group(agents, isGitRoot: { $0 == "/repo/app" })
        #expect(groups.map(\.workspaceId) == ["/loose/dir", "/repo/app"])
        #expect(groups.map(\.label) == ["dir", "app"])
        let app = try #require(groups.last)
        #expect(app.agents.map(\.pid) == [1, 2])   // working sorts before idle
        #expect(app.agentStatus == .working)
    }

    // MARK: - Merge

    @Test func mergeModes() {
        let herdr = [session("default", [agent(1, "/a", session: "S1")]), session("alt", [])]
        let local = session("local", [
            agent(10, "/a", session: "S1"),                 // duplicate of a herdr agent
            agent(11, "/b", herdrParent: true),             // child of herdr
            agent(12, "/c", session: "S3"),
        ], local: true)

        #expect(AgentSourceMerge.merge(herdr: herdr, local: local, mode: .herdr).map(\.name) == ["default", "alt"])
        let localOnly = AgentSourceMerge.merge(herdr: herdr, local: local, mode: .local)
        #expect(localOnly.map(\.name) == ["local"])
        #expect(localOnly[0].workspaces[0].agents.count == 3)

        let both = AgentSourceMerge.merge(herdr: herdr, local: local, mode: .both)
        #expect(both.map(\.name) == ["default", "alt", "local"])
        #expect(both[2].workspaces[0].agents.map(\.pid) == [12])
    }

    @Test func mergeRenamesLocalWhenHerdrSessionUsesThatName() {
        let herdr = [session("local", [agent(1, "/a", session: "S1")]), session("local (this Mac)", [])]
        let local = session("local", [agent(12, "/c", session: "S3")], local: true)
        let both = AgentSourceMerge.merge(herdr: herdr, local: local, mode: .both)
        #expect(both.map(\.name) == ["local", "local (this Mac)", "local (this Mac) (this Mac)"])
        #expect(Set(both.map(\.id)).count == 3)
        #expect(AgentSourceMerge.merge(herdr: [session("d", [])], local: local, mode: .both).map(\.name) == ["d", "local"])
    }

    @Test func mergeHerdrDownKeepsEveryLocalAgentAndDropsEmptyLocal() {
        let local = session("local", [agent(10, "/a", session: "S1"), agent(11, "/b")], local: true)
        let both = AgentSourceMerge.merge(herdr: [], local: local, mode: .both)
        #expect(both.map(\.name) == ["local"])
        #expect(both[0].workspaces[0].agents.count == 2)

        let allDuplicates = session("local", [agent(10, "/a", herdrParent: true)], local: true)
        #expect(AgentSourceMerge.merge(herdr: [], local: allDuplicates, mode: .both).isEmpty)
        #expect(AgentSourceMerge.merge(herdr: [], local: nil, mode: .local).isEmpty)
        #expect(AgentSourceMerge.merge(herdr: [session("d", [])], local: nil, mode: .both).map(\.name) == ["d"])
    }

    // MARK: - Model compatibility

    @Test func herdAgentRoundTripsOriginAndDecodesLegacyPayload() throws {
        let local = agent(7, "/a", herdrParent: true)
        let back = try JSONDecoder().decode(HerdAgent.self, from: JSONEncoder().encode(local))
        #expect(back == local && back.source == .local && back.pid == 7 && back.parentChainHasHerdr)

        let legacy = try JSONDecoder().decode(
            HerdAgent.self,
            from: Data(#"{"agent":"claude","agentStatus":"idle","cwd":"/a","focused":false,"paneId":"p","tabId":"t","workspaceId":"w"}"#.utf8))
        #expect(legacy.source == .herdr && legacy.pid == nil && !legacy.parentChainHasHerdr)
    }
}
