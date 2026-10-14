import Foundation

/// What a Codex rollout tail says about the session.
public struct CodexRolloutState: Sendable, Equatable {
    public let status: AgentStatus
    public init(status: AgentStatus) { self.status = status }
}

/// Reads Codex CLI rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), bounded and read-only.
///
/// Every line is `{"timestamp", "type", "payload"}`. Top-level types seen on this machine: `session_meta`
/// (first line, about 20 KB because of `base_instructions`; payload has `id`, `cwd`, `cli_version`,
/// `originator`), `turn_context`, `response_item`, `event_msg`, `token_usage_record`, `world_state`.
///
/// `event_msg` payload types seen across all local rollouts: `task_started` (turn begins, has `turn_id`),
/// `task_complete` (turn ends), `turn_aborted`, `token_count`, `item_completed`, `agent_message`,
/// `agent_reasoning`, `user_message`, `exec_command_end`, `patch_apply_end`, `web_search_end`,
/// `mcp_tool_call_end`, `sub_agent_activity`, `thread_settings_applied`, `context_compacted`,
/// `thread_rolled_back`, `entered_review_mode`.
///
/// No approval event exists in any local rollout (approval was never requested in them). The names
/// `exec_approval_request`, `apply_patch_approval_request`, `request_user_input` and
/// `elicitation_request` come from the Codex protocol, not from observation, so treat the `blocked` path as
/// unverified against real data.
public enum CodexRolloutReader {
    /// Bytes read from the end of a rollout. A tail this size holds many turns.
    static let tailBytes = 256 * 1024
    /// Bytes read from the start of a rollout to find `session_meta.cwd`, which sits near the front.
    static let headBytes = 4096

    static let approvalEvents: Set<String> = [
        "exec_approval_request", "apply_patch_approval_request", "request_user_input", "elicitation_request",
    ]
    /// Events that prove an approval was answered: the command or patch it gated has started or finished.
    static let resolvingEvents: Set<String> = [
        "exec_command_begin", "exec_command_end", "patch_apply_begin", "patch_apply_end",
        "mcp_tool_call_begin", "mcp_tool_call_end",
    ]

    /// The running fold of lifecycle events, owned by ``CodexRolloutTracker``.
    ///
    /// `task_started` without a later completion is `working`, a completion last is `idle`, an unanswered
    /// approval request is `blocked`, and no lifecycle event at all is `unknown`: a turn longer than the
    /// window read cannot be told from a stalled one, and guessing would mislabel it.
    struct Fold {
        var status: AgentStatus = .unknown
        var pendingApproval = false

        var state: CodexRolloutState { CodexRolloutState(status: pendingApproval ? .blocked : status) }

        mutating func apply(_ line: String) {
            // Cheap pre-filter: most lines are response items, and a bootstrap may scan megabytes.
            guard line.contains("\"event_msg\""),
                let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                (obj["type"] as? String) == "event_msg",
                let kind = (obj["payload"] as? [String: Any])?["type"] as? String
            else { return }
            switch kind {
            case "task_started":
                status = .working
                pendingApproval = false
            case "task_complete", "turn_aborted":
                status = .idle
                pendingApproval = false
            case let k where CodexRolloutReader.approvalEvents.contains(k):
                pendingApproval = true
            case let k where CodexRolloutReader.resolvingEvents.contains(k):
                pendingApproval = false
            default:
                break
            }
        }
    }

    /// `session_meta.cwd` from the first bytes of a rollout, `nil` when absent or unreadable.
    public static func sessionCwd(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.headBytes) else { return nil }
        return Self.sessionCwd(fromHead: String(decoding: data, as: UTF8.self))
    }

    private static let cwdRegex = try! NSRegularExpression(pattern: #""cwd"\s*:\s*("(?:[^"\\]|\\.)*")"#)

    /// Extracts the first `"cwd":"..."` string from a head fragment. The full first line is too large to
    /// parse as JSON from a bounded read, and `cwd` precedes the bulky fields.
    public static func sessionCwd(fromHead head: String) -> String? {
        guard let match = cwdRegex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
            let range = Range(match.range(at: 1), in: head),
            let value = try? JSONSerialization.jsonObject(with: Data(head[range].utf8), options: .fragmentsAllowed) as? String
        else { return nil }
        return value
    }

    /// Rollouts modified within `window` of `now`, newest first. Only the date directories that can
    /// contain them (the day of `now - window` through the day of `now`) are listed.
    public static func recentRollouts(root: URL, now: Date, window: TimeInterval = 24 * 3600) -> [URL] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var found: [(URL, Date)] = []
        for offset in 0...Int(window / 86400) + 1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root
                .appendingPathComponent(String(format: "%04d", c.year ?? 0))
                .appendingPathComponent(String(format: "%02d", c.month ?? 0))
                .appendingPathComponent(String(format: "%02d", c.day ?? 0))
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    now.timeIntervalSince(mtime) <= window
                else { continue }
                found.append((url, mtime))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Incremental Codex status per rollout path: a byte offset plus the folded lifecycle state, so a turn
/// longer than any tail window (a real one grew to about 1 MB in three minutes) keeps its `working` status.
///
/// The first read of a path bootstraps from a bounded tail, widening backwards until a lifecycle event is
/// found; later reads take only appended bytes. A shrunk file or a new inode resets the cursor. Owned by
/// ``LocalAgentSource`` across ticks, the way `TranscriptReader` is owned for Claude.
public final class CodexRolloutTracker: @unchecked Sendable {
    // Safety of @unchecked: every access to `cursors`, `cwds` and `bytesRead` holds `lock`.
    private struct Cursor {
        var inode: UInt64
        /// End of the last complete line folded; a trailing partial line is re-read next time.
        var offset: UInt64
        var fold: CodexRolloutReader.Fold
    }

    /// Widest bootstrap window. A turn with no lifecycle event inside it reads as `unknown`.
    static let maxBootstrapBytes = 16 * 1024 * 1024

    private let lock = NSLock()
    private var cursors: [URL: Cursor] = [:]
    /// Total bytes read from rollouts since creation, for tests asserting an unchanged file costs nothing.
    private(set) var bytesRead = 0
    /// `session_meta.cwd` never changes once written, so each rollout's head is read once.
    private var cwds: [URL: String] = [:]

    public init() {}

    public func state(of url: URL) -> CodexRolloutState {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            cursors[url] = nil
            return CodexRolloutState(status: .unknown)
        }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            cursors[url] = nil
            return CodexRolloutState(status: .unknown)
        }
        let size = UInt64(info.st_size)
        let inode = UInt64(info.st_ino)

        if var cursor = cursors[url], cursor.inode == inode, size >= cursor.offset,
            size - cursor.offset <= UInt64(Self.maxBootstrapBytes)
        {
            guard size > cursor.offset else { return cursor.fold.state }
            if let (lines, consumed) = readLines(handle, from: cursor.offset, to: size) {
                for line in lines { cursor.fold.apply(line) }
                cursor.offset += consumed
                cursors[url] = cursor
                return cursor.fold.state
            }
        }
        guard let cursor = bootstrap(handle, size: size, inode: inode) else {
            cursors[url] = nil
            return CodexRolloutState(status: .unknown)
        }
        cursors[url] = cursor
        return cursor.fold.state
    }

    /// ``CodexRolloutReader/sessionCwd(of:)``, cached per rollout. A `nil` (head not written yet) is retried.
    func cwd(of url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = cwds[url] { return known }
        let read = CodexRolloutReader.sessionCwd(of: url)
        cwds[url] = read
        return read
    }

    /// Forgets every path not in `paths`, so finished rollouts do not accumulate.
    func retain(_ paths: Set<URL>) {
        lock.lock()
        defer { lock.unlock() }
        cursors = cursors.filter { paths.contains($0.key) }
        cwds = cwds.filter { paths.contains($0.key) }
    }

    /// Folds a tail window ending at `size`, doubling it (up to ``maxBootstrapBytes``) until a lifecycle event shows.
    private func bootstrap(_ handle: FileHandle, size: UInt64, inode: UInt64) -> Cursor? {
        var window = UInt64(CodexRolloutReader.tailBytes)
        while true {
            let start = size > window ? size - window : 0
            guard let (lines, consumed) = readLines(handle, from: start, to: size, dropsPartialFirst: start > 0)
            else { return nil }
            var fold = CodexRolloutReader.Fold()
            for line in lines { fold.apply(line) }
            if fold.status != .unknown || start == 0 || window >= UInt64(Self.maxBootstrapBytes) {
                return Cursor(inode: inode, offset: start + consumed, fold: fold)
            }
            window *= 4
        }
    }

    /// Complete lines in `[from, to)` and the byte count they span. A trailing partial line is left unread.
    /// With `dropsPartialFirst`, `from` may fall mid-line, so everything up to the first newline is skipped
    /// (and counted in `consumed`).
    private func readLines(
        _ handle: FileHandle, from: UInt64, to: UInt64, dropsPartialFirst: Bool = false
    ) -> (lines: [String], consumed: UInt64)? {
        guard (try? handle.seek(toOffset: from)) != nil,
            let data = try? handle.read(upToCount: Int(to - from))
        else { return nil }
        bytesRead += data.count
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        var body = data[data.startIndex...lastNewline]
        if dropsPartialFirst, let firstNewline = body.firstIndex(of: 0x0A) {
            body = body[body.index(after: firstNewline)...]
        }
        let lines = String(decoding: body, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, UInt64(lastNewline - data.startIndex + 1))
    }
}
