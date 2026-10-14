import Foundation

/// One tool call, reduced to what a one-line "now doing" label needs.
public struct ToolSummary: Sendable, Equatable {
    public let name: String
    /// Short single-line target (file basename, command, pattern), already truncated.
    public let target: String?

    public init(name: String, target: String?) {
        self.name = name
        self.target = target
    }

    /// `Edit NotchToast.swift`, or just the tool name when there is no target.
    public var display: String {
        let shown = ToolSummarizer.displayName(name)
        return target.map { "\(shown) \($0)" } ?? shown
    }
}

/// What a Claude Code agent is doing right now, derived from its transcript.
public struct AgentActivity: Sendable, Equatable {
    /// Newest tool_use with no tool_result yet.
    public var currentTool: ToolSummary?
    /// Human phrasing of the pending tool as a question or permission request, nil when nothing is pending.
    public var pendingAsk: String?
    /// Prompt size of the latest main-thread assistant turn.
    public var contextTokens: Int?
    public var contextLimit: Int
    public var runningSubagents: Int

    public init(
        currentTool: ToolSummary? = nil, pendingAsk: String? = nil, contextTokens: Int? = nil,
        contextLimit: Int = 200_000, runningSubagents: Int = 0
    ) {
        self.currentTool = currentTool
        self.pendingAsk = pendingAsk
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.runningSubagents = runningSubagents
    }

    /// Context fill in 0...1 (clamped), nil when no usage has been seen.
    public var contextFraction: Double? {
        contextTokens.map { min(1, max(0, Double($0) / Double(contextLimit))) }
    }
}

enum ToolSummarizer {
    static let maxTarget = 48

    /// Tool name for display: MCP names (`mcp__server__tool`) shrink to the last segment, then clean and truncate.
    static func displayName(_ name: String) -> String {
        let short = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
        return firstLine(short).map(truncate) ?? ""
    }

    static func target(name: String, input: [String: Any]) -> String? {
        func str(_ k: String) -> String? { input[k] as? String }
        let raw: String?
        switch name {
        case "Bash":
            if let d = str("description"), !d.isEmpty { raw = d } else { raw = str("command").flatMap(firstLine) }
        case "Edit", "Write", "Read", "NotebookEdit":
            raw = str("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": raw = str("pattern")
        case "Agent", "Task": raw = str("description")
        case "Skill": raw = str("skill")
        case "WebFetch": raw = str("url").flatMap { URL(string: $0)?.host ?? $0 }
        case "WebSearch": raw = str("query")
        default: raw = nil
        }
        return raw.flatMap(firstLine).map(truncate)
    }

    /// First non-empty line, trimmed, with control characters (as spaces) and Unicode format characters
    /// (bidi overrides, zero-width) removed. Nil for blank input.
    static func firstLine(_ s: String) -> String? {
        for raw in s.split(whereSeparator: \.isNewline) {
            var cleaned = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                if scalar.properties.generalCategory == .format {
                    continue
                } else if CharacterSet.controlCharacters.contains(scalar) {
                    cleaned.append(" ")
                } else {
                    cleaned.append(scalar)
                }
            }
            let line = String(cleaned).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return nil
    }

    static func truncate(_ s: String) -> String {
        s.count > maxTarget ? String(s.prefix(maxTarget - 1)) + "\u{2026}" : s
    }

    static func ask(name: String, input: [String: Any]) -> String {
        switch name {
        case "AskUserQuestion":
            let questions = input["questions"] as? [[String: Any]]
            if let q = questions?.first?["question"] as? String, let line = firstLine(q) {
                return "asks: \(truncate(line))"
            }
            return "asks a question"
        case "Bash":
            if let c = (input["command"] as? String).flatMap(firstLine) { return "wants to run: \(truncate(c))" }
            return "wants to run a command"
        case "Edit", "Write":
            if let p = input["file_path"] as? String { return "wants to edit \(truncate((p as NSString).lastPathComponent))" }
            return "wants to edit a file"
        default: return "wants to use \(displayName(name))"
        }
    }
}

/// Incremental tail reader for one Claude Code transcript (`<uuid>.jsonl`).
///
/// Not thread-safe: own it from a single serial context. Never writes to the file.
public final class TranscriptReader {
    static let initialWindow: UInt64 = 2 * 1024 * 1024
    static let maxPending = 64
    // ponytail: no transcript field exposes the window size; 1M if a [1m] model or any turn exceeded 200k.
    // Upgrade when the transcript or herdr reports the real window.
    static let smallWindow = 200_000
    static let largeWindow = 1_000_000

    public let url: URL
    private var offset: UInt64 = 0
    private var carry = Data()
    private var started = false
    private var pending: [(id: String, summary: ToolSummary, ask: String)] = []
    private var contextTokens: Int?
    private var maxContext = 0
    private var model: String?

    public init(url: URL) { self.url = url }

    /// Reads any new bytes and returns the current snapshot (subagent count left at 0 for the caller).
    public func read() -> AgentActivity {
        ingest()
        return snapshot()
    }

    func snapshot() -> AgentActivity {
        let large = (model?.contains("[1m]") ?? false) || maxContext > Self.smallWindow
        let last = pending.last
        return AgentActivity(
            currentTool: last?.summary, pendingAsk: last?.ask, contextTokens: contextTokens,
            contextLimit: large ? Self.largeWindow : Self.smallWindow
        )
    }

    private func reset() {
        offset = 0; carry = Data(); started = false
        pending = []; contextTokens = nil; maxContext = 0; model = nil
    }

    private func ingest() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        // Behind the file by more than the window (reader idled), or file shrank: start fresh from the tail.
        if started && (size < offset || size - offset > Self.initialWindow) { reset() }
        var discardFirst = false
        if !started {
            started = true
            offset = size > Self.initialWindow ? size - Self.initialWindow : 0
            discardFirst = offset > 0
        }
        guard size > offset else { return }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty
        else { return }
        offset += UInt64(data.count)

        var buffer = carry
        buffer.append(data)
        var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
        carry = Data(lines.removeLast())
        if discardFirst, !lines.isEmpty { lines.removeFirst() }
        // A partial first line with no newline in the window: carry is the partial, so drop it too.
        if discardFirst, lines.isEmpty { carry = Data() }
        for line in lines where !line.isEmpty { process(Data(line)) }
    }

    private func process(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let type = obj["type"] as? String
        else { return }
        if (obj["isSidechain"] as? Bool) == true { return }
        guard let message = obj["message"] as? [String: Any] else { return }
        if type == "assistant" {
            // `<synthetic>` rows (API errors, interrupts) and zero-usage rows carry no real prompt size.
            let rowModel = message["model"] as? String
            let usage = message["usage"] as? [String: Any]
            func n(_ k: String) -> Int { (usage?[k] as? NSNumber)?.intValue ?? 0 }
            let total = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            if rowModel != "<synthetic>" && !(usage != nil && total == 0) {
                if let rowModel { model = rowModel }
                if usage != nil {
                    contextTokens = total
                    maxContext = max(maxContext, total)
                }
            }
            for block in message["content"] as? [[String: Any]] ?? [] where (block["type"] as? String) == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                pending.append((id, ToolSummary(name: name, target: ToolSummarizer.target(name: name, input: input)), ToolSummarizer.ask(name: name, input: input)))
            }
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        } else if type == "user" {
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks where (block["type"] as? String) == "tool_result" {
                if let id = block["tool_use_id"] as? String { pending.removeAll { $0.id == id } }
            }
        }
    }
}

/// Counts running subagents from `<session>/subagents/agent-*.jsonl`.
public enum SubagentCounter {
    static let freshness: TimeInterval = 10 * 60
    static let tailBytes: UInt64 = 64 * 1024

    /// Files modified within ten minutes whose last row is not an assistant `end_turn`.
    public static func count(in dir: URL, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var running = 0
        for url in urls where url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now.timeIntervalSince(mtime) <= freshness
            else { continue }
            if !isFinished(url) { running += 1 }
        }
        return running
    }

    static let retryTailBytes: UInt64 = 2 * 1024 * 1024

    static func isFinished(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        // A last line longer than the tail leaves no complete line: retry wider, then call it finished.
        if let done = lastRowFinished(handle, size: size, tail: tailBytes) { return done }
        guard size > tailBytes else { return false }
        return lastRowFinished(handle, size: size, tail: retryTailBytes) ?? true
    }

    /// Whether the last complete row is an assistant `end_turn`; nil when the tail holds no parseable row.
    private static func lastRowFinished(_ handle: FileHandle, size: UInt64, tail: UInt64) -> Bool? {
        let start = size > tail ? size - tail : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let lines = data.split(separator: 0x0A).map { Data($0) }
        // Ignore the first line of a mid-file tail: it may be cut.
        let candidates = start > 0 ? Array(lines.dropFirst()) : lines
        for line in candidates.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let message = obj["message"] as? [String: Any]
            return (obj["type"] as? String) == "assistant" && (message?["stop_reason"] as? String) == "end_turn"
        }
        return nil
    }
}

/// Maps a Claude session UUID to its transcript file by globbing `<projects>/*/<uuid>.jsonl`.
///
/// Not thread-safe: own it from a single serial context.
public final class TranscriptLocator {
    static let missRetry: TimeInterval = 30
    public let projectsRoot: URL
    private var found: [String: URL] = [:]
    private var missedAt: [String: Date] = [:]

    /// - Parameter projectsRoot: Defaults to `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`.
    public init(projectsRoot: URL? = nil) {
        if let projectsRoot {
            self.projectsRoot = projectsRoot
        } else if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            self.projectsRoot = URL(fileURLWithPath: dir).appendingPathComponent("projects")
        } else {
            self.projectsRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
        }
    }

    public func locate(_ uuid: String, now: Date = Date()) -> URL? {
        // The id comes from herdr output: never let it escape the project directory.
        guard !uuid.isEmpty, !uuid.contains("/"), !uuid.contains(".."), !uuid.contains("\0") else { return nil }
        if let url = found[uuid] { return url }
        if let t = missedAt[uuid], now.timeIntervalSince(t) < Self.missRetry { return nil }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(uuid).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                found[uuid] = candidate
                missedAt[uuid] = nil
                return candidate
            }
        }
        missedAt[uuid] = now
        return nil
    }

    /// Subagents directory next to a located transcript.
    public static func subagentsDir(for transcript: URL) -> URL {
        transcript.deletingPathExtension().appendingPathComponent("subagents")
    }
}
