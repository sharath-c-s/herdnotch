import Foundation
import Testing

@testable import HerdKit

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

private struct Procs: ProcessInspecting {
    struct P {
        var name = "x"
        var ppid: Int32 = 1
        var start: Int64 = 0
    }
    var procs: [Int32: P]
    func allPids() -> [Int32] { Array(procs.keys) }
    func isAlive(_ pid: Int32) -> Bool { procs[pid] != nil }
    func startTime(of pid: Int32) -> Int64? { procs[pid]?.start }
    func name(of pid: Int32) -> String? { procs[pid]?.name }
    func argv(of pid: Int32) -> [String]? { nil }
    func parentPid(of pid: Int32) -> Int32? { procs[pid]?.ppid }
    func cwd(of pid: Int32) -> String? { nil }
    func tty(of pid: Int32) -> String? { nil }
    func openRolloutPath(of pid: Int32) -> String? { nil }
}

struct ReviewFixTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func event(_ type: String) -> String {
        #"{"timestamp":"2026-10-13T10:49:18.634Z","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func noise(_ count: Int) -> String {
        String(repeating: event("token_count") + "\n", count: count)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - F1

    @Test func codexWorkingSurvivesMoreThanTheTailWindowOfAppendedNoise() throws {
        let url = try tempDir().appendingPathComponent("rollout-a.jsonl")
        try Data((event("task_complete") + "\n" + event("task_started") + "\n").utf8).write(to: url)
        let tracker = CodexRolloutTracker()
        #expect(tracker.state(of: url).status == .working)

        let chunk = noise(6000)
        #expect(chunk.utf8.count > 256 * 1024)
        try append(chunk, to: url)
        let before = tracker.bytesRead
        #expect(tracker.state(of: url).status == .working)
        #expect(tracker.bytesRead - before == chunk.utf8.count)  // only the appended bytes

        try append(event("task_complete") + "\n", to: url)
        #expect(tracker.state(of: url).status == .idle)
    }

    @Test func codexUnchangedRolloutReadsZeroBytes() throws {
        let url = try tempDir().appendingPathComponent("rollout-a.jsonl")
        try Data((event("task_started") + "\n").utf8).write(to: url)
        let tracker = CodexRolloutTracker()
        #expect(tracker.state(of: url).status == .working)
        let before = tracker.bytesRead
        #expect(tracker.state(of: url).status == .working)
        #expect(tracker.bytesRead == before)
    }

    @Test func codexBootstrapWidensPastTheTailToFindTheLifecycleEvent() throws {
        let url = try tempDir().appendingPathComponent("rollout-a.jsonl")
        try Data((event("task_started") + "\n" + noise(6000)).utf8).write(to: url)
        #expect(CodexRolloutTracker().state(of: url).status == .working)
    }

    @Test func codexTruncationResetsTheCursor() throws {
        let url = try tempDir().appendingPathComponent("rollout-a.jsonl")
        try Data((event("task_started") + "\n" + noise(50)).utf8).write(to: url)
        let tracker = CodexRolloutTracker()
        #expect(tracker.state(of: url).status == .working)
        try Data((event("task_complete") + "\n").utf8).write(to: url)
        #expect(tracker.state(of: url).status == .idle)
    }

    @Test func codexPartialTrailingLineIsReadOnceComplete() throws {
        let url = try tempDir().appendingPathComponent("rollout-a.jsonl")
        try Data((event("task_complete") + "\n" + String(event("task_started").dropLast(5))).utf8).write(to: url)
        let tracker = CodexRolloutTracker()
        #expect(tracker.state(of: url).status == .idle)
        try append(String(event("task_started").suffix(5)) + "\n", to: url)
        #expect(tracker.state(of: url).status == .working)
    }

    // MARK: - F2, F5

    private func registry(_ dir: URL, entries: [(pid: Int32, id: String, status: String)]) throws {
        let start = ClaudeSessionRegistry.parseProcStart("Tue Oct 13 12:33:29 2026")!
        for e in entries {
            let obj: [String: Any] = ["pid": e.pid, "sessionId": e.id, "cwd": "/p/\(e.pid)", "status": e.status,
                "name": "", "procStart": "Tue Oct 13 12:33:29 2026"]
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("\(e.pid).json"))
        }
        _ = start
    }

    private func source(_ dir: URL, procs: Procs, calls: Calls) throws -> LocalAgentSource {
        LocalAgentSource(
            registry: ClaudeSessionRegistry(directory: dir, processes: procs), processes: procs,
            codexRoot: try tempDir(), isGitRoot: { _ in false },
            pendingAsk: { calls.add($0); return nil })
    }

    @Test func pendingAskSkipsAgentsTheMergeDrops() throws {
        let dir = try tempDir()
        try registry(dir, entries: [(10, "hosted", "idle"), (11, "free", "idle"), (12, "dup", "idle")])
        let start = ClaudeSessionRegistry.parseProcStart("Tue Oct 13 12:33:29 2026")!
        let procs = Procs(procs: [
            10: .init(ppid: 5, start: start), 11: .init(start: start), 12: .init(start: start),
            5: .init(name: "herdr"),
        ])
        let calls = Calls()
        let known: Set<String> = ["dup"]
        let sessions = try source(dir, procs: procs, calls: calls).sessions(excluding: {
            AgentSourceMerge.isDuplicate($0, knownSessionIds: known)
        })
        #expect(calls.all == ["free"])
        #expect(sessions.flatMap(\.workspaces).flatMap(\.agents).map(\.pid) == [11])
    }

    @Test func registryWaitingIsBlockedWithoutATranscriptRead() throws {
        let dir = try tempDir()
        try registry(dir, entries: [(20, "w", "waiting")])
        let start = ClaudeSessionRegistry.parseProcStart("Tue Oct 13 12:33:29 2026")!
        let calls = Calls()
        let agents = try source(dir, procs: Procs(procs: [20: .init(start: start)]), calls: calls)
            .sessions().flatMap(\.workspaces).flatMap(\.agents)
        #expect(agents.first?.agentStatus == .blocked)
        #expect(calls.all.isEmpty)
    }

    // MARK: - F4

    private func session(_ name: String, socket: String) -> HerdSession {
        HerdSession(name: name, isDefault: false, running: true, socketPath: socket, workspaces: [])
    }

    @Test func rosterAlwaysOffersLocalOutsideHerdrMode() {
        let herdrOnly = [session("default", socket: "/s")]
        #expect(AgentSourceMerge.rosterNames(herdrOnly, mode: .both) == ["default", "local"])
        #expect(AgentSourceMerge.rosterNames(herdrOnly, mode: .local) == ["default", "local"])
        #expect(AgentSourceMerge.rosterNames(herdrOnly, mode: .herdr) == ["default"])
        // Already present, no duplicate.
        let withLocal = herdrOnly + [session("local", socket: "")]
        #expect(AgentSourceMerge.rosterNames(withLocal, mode: .both) == ["default", "local"])
        // A herdr session named `local` pushes the local one to its renamed variant, hidden or shown.
        let clash = [session("local", socket: "/s")]
        #expect(AgentSourceMerge.rosterNames(clash, mode: .both) == ["local", "local (this Mac)"])
        #expect(AgentSourceMerge.rosterNames(clash + [session("local (this Mac)", socket: "")], mode: .both)
            == ["local", "local (this Mac)"])
    }

    // MARK: - F7

    @Test func groupingStatsEachDirectoryOnce() {
        let calls = Calls()
        func agent(_ pid: Int32) -> HerdAgent {
            HerdAgent(agent: "claude", agentStatus: .idle, cwd: "/p/a/b", paneId: "l:\(pid)", tabId: "l", workspaceId: "l",
                source: .local, pid: pid)
        }
        _ = LocalAgentSource.group([agent(1), agent(2), agent(3)], isGitRoot: { calls.add($0); return false })
        #expect(calls.all.count == Set(calls.all).count)
    }
}
