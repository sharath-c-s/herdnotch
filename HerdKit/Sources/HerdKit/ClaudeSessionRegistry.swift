import Foundation

/// One `~/.claude/sessions/<pid>.json` record, reduced to the fields the panel uses.
public struct ClaudeRegistryEntry: Sendable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    /// Claude's own `name` for the session, empty when absent.
    public let name: String
    /// Who set ``name``: observed `user` (/rename), `auto` (Claude's title), `derived`. Empty when absent.
    public let nameSource: String
    /// Raw registry status: observed `busy`, `idle`, `shell`.
    public let status: String
    /// Process start as whole epoch seconds, parsed from the `procStart` string, which Claude writes in UTC.
    public let procStart: Int64?

    public init(pid: Int32, sessionId: String, cwd: String, name: String, nameSource: String = "", status: String, procStart: Int64?) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.procStart = procStart
    }
}

/// Reads Claude Code's per-process session registry and filters it to live processes.
///
/// Stale files (the process died or its pid was reused) are skipped, never deleted: the registry is
/// Claude's, not ours. `*.key` files in the directory are never opened. Another user's pid has no readable
/// start time, so it is never live even though `kill(pid, 0)` reports it exists.
public struct ClaudeSessionRegistry: Sendable {
    /// Allowed drift between the registry's `procStart` and the kernel's start time.
    static let startTolerance: Int64 = 2

    public let directory: URL
    public let processes: any ProcessInspecting

    /// - Parameter directory: Defaults to `$CLAUDE_CONFIG_DIR/sessions`, else `~/.claude/sessions`.
    public init(directory: URL? = nil, processes: any ProcessInspecting = DarwinProcessInspector()) {
        if let directory {
            self.directory = directory
        } else if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            self.directory = URL(fileURLWithPath: dir).appendingPathComponent("sessions")
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        }
        self.processes = processes
    }

    /// Entries whose process is alive and whose start time matches `procStart`.
    public func liveEntries() -> [ClaudeRegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(Self.parse)
            .filter(isLive)
            .sorted { $0.pid < $1.pid }
    }

    func isLive(_ entry: ClaudeRegistryEntry) -> Bool {
        guard processes.isAlive(entry.pid), let expected = entry.procStart,
            let actual = processes.startTime(of: entry.pid)
        else { return false }
        return abs(actual - expected) <= Self.startTolerance
    }

    /// Parses one registry file. `nil` when it is not JSON or lacks `pid`, `sessionId` or `cwd`.
    public static func parse(_ data: Data) -> ClaudeRegistryEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let pid = (obj["pid"] as? NSNumber)?.int32Value,
            let sessionId = obj["sessionId"] as? String,
            let cwd = obj["cwd"] as? String
        else { return nil }
        return ClaudeRegistryEntry(
            pid: pid, sessionId: sessionId, cwd: cwd,
            name: obj["name"] as? String ?? "",
            nameSource: obj["nameSource"] as? String ?? "",
            status: obj["status"] as? String ?? "",
            procStart: (obj["procStart"] as? String).flatMap { parseProcStart($0) }
        )
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private static let utcFormatter = makeFormatter(utc)

    private static func makeFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }

    /// Parses a ctime-style string such as `Tue Oct 13 12:33:29 2026` (day may be space padded).
    ///
    /// - Parameter timeZone: The zone the string was written in. Claude writes `procStart` in UTC
    ///   whatever the machine's zone, so that is the default.
    public static func parseProcStart(_ text: String, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Int64? {
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = timeZone == Self.utc ? Self.utcFormatter : Self.makeFormatter(timeZone)
        return formatter.date(from: normalized).map { Int64($0.timeIntervalSince1970.rounded()) }
    }
}
