import Foundation

/// Mirrors `ProcessInfo.ThermalState`, which NotchCore cannot reference without the platform value.
public enum ThermalLevel: Int, Equatable, Comparable, Sendable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Reads `pmset -g therm`.
public enum PmsetTherm {
    /// The `CPU_Speed_Limit` percentage, or `nil` when the output has none (the "No thermal warning level has
    /// been recorded" form). 100 means no limit.
    public static func cpuSpeedLimit(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "CPU_Speed_Limit", let value = Int(parts[1]) { return value }
        }
        return nil
    }
}

/// One row of `/bin/ps -axo pid=,ppid=,pcpu=,rss=,uid=,comm=`: the only view of root and other users' processes.
public struct PsEntry: Equatable, Sendable {
    public var pid: Int32
    public var parentPid: Int32
    /// `ps` decaying average, 100 per core like the direct scan.
    public var cpuPercent: Double
    public var rssBytes: UInt64
    public var uid: UInt32
    /// Last path component of `comm`; the full path stays out of the UI.
    public var name: String

    public init(pid: Int32, parentPid: Int32, cpuPercent: Double, rssBytes: UInt64, uid: UInt32, name: String) {
        self.pid = pid
        self.parentPid = parentPid
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.uid = uid
        self.name = name
    }
}

public enum PsTable {
    public static let arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,uid=,comm="]

    /// Skips malformed lines. `comm` is the rest of the line, so paths with spaces survive.
    public static func parse(_ output: String) -> [PsEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            while fields.count < 5 {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            let comm = rest.trimmingCharacters(in: .whitespaces)
            let name = (comm as NSString).lastPathComponent
            guard let pid = Int32(fields[0]), let parent = Int32(fields[1]), let cpu = Double(fields[2]),
                let rss = UInt64(fields[3]), let uid = UInt32(fields[4]), !name.isEmpty
            else { return nil }
            return PsEntry(pid: pid, parentPid: parent, cpuPercent: cpu, rssBytes: rss &* 1024, uid: uid, name: name)
        }
    }

    /// Usages for the processes the direct scan could not read. `selfPid` children (the `ps` run itself) are dropped.
    public static func usages(
        _ entries: [PsEntry], excluding scanned: Set<Int32>, currentUid: UInt32, selfPid: Int32
    ) -> [ProcessUsage] {
        entries.compactMap { entry in
            guard !scanned.contains(entry.pid), entry.parentPid != selfPid else { return nil }
            return ProcessUsage(
                pid: entry.pid, name: entry.name, family: ResourceDiagnosis.family(name: entry.name, argv: nil),
                cpuPercent: entry.cpuPercent, residentBytes: entry.rssBytes, parentPid: entry.parentPid,
                isSystem: entry.uid != currentUid)
        }
    }
}

public enum HealthLevel: Int, Equatable, Comparable, Sendable {
    case ok, elevated, limiting

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every instantaneous reading the Health page shows. Disk and speed limit are `nil` until first measured.
public struct HealthReadings: Equatable, Sendable {
    public var cpuPercent: Double
    public var loadAverage: Double
    public var cores: Int
    public var memory: MemoryReading
    public var swapGrowing: Bool
    /// Used share of the boot volume, 0 to 100.
    public var diskUsedPercent: Double?
    public var thermal: ThermalLevel
    public var cpuSpeedLimit: Int?
    public var lowPowerMode: Bool

    public init(
        cpuPercent: Double, loadAverage: Double, cores: Int, memory: MemoryReading, swapGrowing: Bool = false,
        diskUsedPercent: Double? = nil, thermal: ThermalLevel = .nominal, cpuSpeedLimit: Int? = nil,
        lowPowerMode: Bool = false
    ) {
        self.cpuPercent = cpuPercent
        self.loadAverage = loadAverage
        self.cores = cores
        self.memory = memory
        self.swapGrowing = swapGrowing
        self.diskUsedPercent = diskUsedPercent
        self.thermal = thermal
        self.cpuSpeedLimit = cpuSpeedLimit
        self.lowPowerMode = lowPowerMode
    }

    /// The CPU is being slowed down by heat, whether `pmset` says so or the OS thermal state does.
    public var isThermallyLimited: Bool {
        if let cpuSpeedLimit, cpuSpeedLimit < 100 { return true }
        return thermal >= .serious
    }
}

public struct HealthRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var value: String
    /// 0...1 for the thin bar; `nil` for rows that are a state, not an amount.
    public var fraction: Double?
    public var level: HealthLevel
}

/// What a suggestion points at: a process, an agent session (matched by pid or session id), or nothing.
public enum SuggestionTarget: Equatable, Sendable {
    case none
    case process(pid: Int32)
    case agent(pid: Int32, sessionId: String?)
}

public struct HealthSuggestion: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    /// 0...100, higher first. Not a unit: thermal limits and swapping (80+) outrank a big app (capped at 75), which outranks Low Power Mode.
    public var impact: Int
    public var target: SuggestionTarget
}

public struct ProcessNode: Equatable, Sendable {
    public var parentPid: Int32
    public var name: String
    public var argv: [String]?

    public init(parentPid: Int32, name: String, argv: [String]? = nil) {
        self.parentPid = parentPid
        self.name = name
        self.argv = argv
    }
}

public struct AgentIdentity: Equatable, Sendable {
    public var label: String
    public var sessionId: String?
    /// The Claude registry status ("busy", "idle", "shell"); `nil` for agents without one (Codex).
    public var registryStatus: String?

    public init(label: String, sessionId: String? = nil, registryStatus: String? = nil) {
        self.label = label
        self.sessionId = sessionId
        self.registryStatus = registryStatus
    }
}

/// An agent session and the processes it spawned (MCP servers, tools, helpers).
public struct AgentSwarm: Equatable, Sendable, Identifiable {
    public var id: Int32 { agentPid }
    public var agentPid: Int32
    public var identity: AgentIdentity
    public var count: Int
    public var mcpCount: Int
    public var cpuPercent: Double
    public var residentBytes: UInt64

    /// A registry status wins; agents without one fall back to low swarm CPU.
    // ponytail: Codex has no status, so idle there means low swarm CPU only.
    public var isIdle: Bool {
        if let status = identity.registryStatus { return status == "idle" }
        return cpuPercent < HealthReport.idleSwarmCPU
    }
}

public enum AgentAttribution {
    public static let maxHops = 64

    /// The nearest ancestor of `pid` that is a known agent (`agents` is keyed by pid) or looks like one by
    /// name (`claude`, `codex`, or an interpreter running a script of that name); the process itself never counts.
    public static func owner(
        of pid: Int32, table: [Int32: ProcessNode], agents: [Int32: AgentIdentity]
    ) -> (pid: Int32, identity: AgentIdentity)? {
        // A registered agent is its own root: it is never swallowed into an unregistered ancestor's swarm.
        if agents[pid] != nil { return nil }
        var current = table[pid]?.parentPid
        var hops = 0
        while let ancestor = current, ancestor > 1, hops < maxHops {
            if let identity = agents[ancestor] { return (ancestor, identity) }
            if let node = table[ancestor], let kind = agentKind(node) {
                return (ancestor, AgentIdentity(label: "\(kind) (\(ancestor))"))
            }
            current = table[ancestor]?.parentPid
            hops += 1
        }
        return nil
    }

    /// Claude's native binary can be named by its version ("2.1.316"), which counts as `claude`.
    static func agentKind(_ node: ProcessNode) -> String? {
        let known = ["claude", "codex"]
        let name = node.name.lowercased()
        if known.contains(name) { return name }
        if isVersionName(name) { return "claude" }
        guard ResourceDiagnosis.isInterpreter(node.name), let argv = node.argv else { return nil }
        for argument in argv.prefix(3) {
            let base = (argument as NSString).lastPathComponent.lowercased()
            if known.contains(base) { return base }
        }
        return nil
    }

    private static func isVersionName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// The process is an agent itself: registered, named like one, or a `bg-pty-host` whose parent chain reaches one.
    public static func isAgentProcess(
        _ process: ProcessUsage, table: [Int32: ProcessNode], agents: [Int32: AgentIdentity]
    ) -> Bool {
        if agents[process.pid] != nil { return true }
        let node = table[process.pid] ?? ProcessNode(parentPid: process.parentPid, name: process.name)
        if agentKind(node) != nil { return true }
        guard node.name == "bg-pty-host" else { return false }
        var current: Int32? = node.parentPid
        var hops = 0
        while let ancestor = current, ancestor > 1, hops < maxHops {
            if agents[ancestor] != nil { return true }
            if let parent = table[ancestor], agentKind(parent) != nil { return true }
            current = table[ancestor]?.parentPid
            hops += 1
        }
        return false
    }

    /// Groups every descendant of each agent under it; agents with fewer than `minMembers` descendants are
    /// left out. Largest memory first, ties by label.
    public static func swarms(
        processes: [ProcessUsage], table: [Int32: ProcessNode], agents: [Int32: AgentIdentity], minMembers: Int = 2
    ) -> [AgentSwarm] {
        var groups: [Int32: AgentSwarm] = [:]
        for process in processes {
            guard let owner = owner(of: process.pid, table: table, agents: agents) else { continue }
            var group = groups[owner.pid] ?? AgentSwarm(
                agentPid: owner.pid, identity: owner.identity, count: 0, mcpCount: 0, cpuPercent: 0, residentBytes: 0)
            group.count += 1
            if process.family == ResourceDiagnosis.mcpFamily { group.mcpCount += 1 }
            group.cpuPercent += process.cpuPercent
            group.residentBytes += process.residentBytes
            groups[owner.pid] = group
        }
        return groups.values.filter { $0.count >= minMembers }.sorted {
            if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            return ($0.identity.label, $0.agentPid) < ($1.identity.label, $1.agentPid)
        }
    }
}

public struct HealthReport: Equatable, Sendable {
    public var readings: HealthReadings
    public var rows: [HealthRow]
    public var topCPU: [ProcessUsage]
    public var topMemory: [ProcessUsage]
    public var agentSwarms: [AgentSwarm]
    /// Swarms of one kind (for example MCP servers) that no agent owns.
    public var otherSwarms: [Swarm]
    public var suggestions: [HealthSuggestion]

    public static let listLimit = 5
    public static let swarmListLimit = 5
    /// A swarm without a registry status under this CPU share (percent of one core) counts as idle.
    public static let idleSwarmCPU = 2.0
    public static let idleSwarmMinBytes: UInt64 = 500 * 1024 * 1024
    public static let bigAppBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let spotlightCPU = 25.0
    public static let systemProcessCPU = 50.0
    public static let selfCPU = 5.0
    public static let selfBytes: UInt64 = 1024 * 1024 * 1024
    public static let diskWarnUsed = 90.0

    /// `selfPid` is HerdNotch's own pid, for the "HerdNotch itself" rule.
    public static func build(
        readings: HealthReadings, processes: [ProcessUsage], table: [Int32: ProcessNode],
        agents: [Int32: AgentIdentity], selfPid: Int32
    ) -> HealthReport {
        // An agent's own process is named by its session (its executable can be just a version number).
        let named = processes.map { process -> ProcessUsage in
            guard let identity = agents[process.pid] else { return process }
            var renamed = process
            renamed.name = identity.label
            return renamed
        }
        let (byCPU, byMemory) = ResourceDiagnosis.rankings(
            cpuPercent: readings.cpuPercent, memory: readings.memory, processes: named, cores: readings.cores)
        let swarms = AgentAttribution.swarms(processes: processes, table: table, agents: agents)
        let owned = Set(processes.filter {
            AgentAttribution.owner(of: $0.pid, table: table, agents: agents) != nil
        }.map(\.pid))
        let unowned = processes.filter {
            !owned.contains($0.pid) && !AgentAttribution.isAgentProcess($0, table: table, agents: agents)
        }
        let top = (cpu: Array(byCPU.prefix(listLimit)), memory: Array(byMemory.prefix(listLimit)))
        return HealthReport(
            readings: readings,
            rows: rows(for: readings),
            topCPU: top.cpu,
            topMemory: top.memory,
            agentSwarms: Array(swarms.prefix(swarmListLimit)),
            otherSwarms: Array(ResourceDiagnosis.swarms(in: unowned).prefix(swarmListLimit)),
            suggestions: suggestions(
                readings: readings, processes: unowned, agentSwarms: swarms, topCPU: top.cpu, topMemory: top.memory,
                selfPid: selfPid))
    }

    // MARK: - Rows

    public static func rows(for r: HealthReadings) -> [HealthRow] {
        var rows: [HealthRow] = []
        rows.append(HealthRow(
            id: "cpu", title: "CPU", value: LoadFormat.percent(r.cpuPercent), fraction: r.cpuPercent / 100,
            level: r.cpuPercent >= ResourceDiagnosis.cpuThreshold ? .limiting : (r.cpuPercent >= 60 ? .elevated : .ok)))
        let perCore = r.loadAverage / Double(max(r.cores, 1))
        rows.append(HealthRow(
            id: "load", title: "Load", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), r.loadAverage),
            fraction: perCore / 2, level: perCore >= 1.5 ? .limiting : (perCore >= 1 ? .elevated : .ok)))
        let memoryLevel: HealthLevel = r.memory.pressure == .critical ? .limiting
            : (r.memory.pressure == .warn || r.memory.usedFraction >= 0.85 ? .elevated : .ok)
        rows.append(HealthRow(
            id: "memory", title: "Memory", value: LoadFormat.memory(used: r.memory.usedBytes, total: r.memory.totalBytes),
            fraction: r.memory.usedFraction, level: memoryLevel))
        let swap = r.memory.swapUsedBytes
        let swapLevel: HealthLevel = r.swapGrowing && r.memory.pressure >= .warn ? .limiting
            : (r.swapGrowing || swap >= 1024 * 1024 * 1024 ? .elevated : .ok)
        rows.append(HealthRow(
            id: "swap", title: "Swap", value: swap == 0 ? "none" : LoadFormat.bytes(swap), fraction: nil, level: swapLevel))
        if let used = r.diskUsedPercent {
            rows.append(HealthRow(
                id: "disk", title: "Disk", value: "\(LoadFormat.percent(used)) full", fraction: used / 100,
                level: used >= diskWarnUsed ? .limiting : (used >= 80 ? .elevated : .ok)))
        }
        let thermalValue = r.cpuSpeedLimit.flatMap { $0 < 100 ? "CPU limited to \($0)%" : nil } ?? "\(r.thermal)"
        rows.append(HealthRow(
            id: "thermal", title: "Thermal", value: thermalValue, fraction: nil,
            level: r.isThermallyLimited ? .limiting : (r.thermal == .fair ? .elevated : .ok)))
        rows.append(HealthRow(
            id: "lowpower", title: "Low Power Mode", value: r.lowPowerMode ? "on" : "off", fraction: nil,
            level: r.lowPowerMode ? .elevated : .ok))
        return rows
    }

    // MARK: - Suggestions

    static func isSpotlight(_ name: String) -> Bool {
        ["mds", "mdworker", "corespotlightd", "spotlightknowledged"].contains { name.hasPrefix($0) }
    }

    static func suggestions(
        readings r: HealthReadings, processes: [ProcessUsage], agentSwarms: [AgentSwarm],
        topCPU: [ProcessUsage], topMemory: [ProcessUsage], selfPid: Int32
    ) -> [HealthSuggestion] {
        var out: [HealthSuggestion] = []
        func add(_ id: String, _ text: String, _ impact: Int, _ target: SuggestionTarget = .none) {
            out.append(HealthSuggestion(id: id, text: text, impact: impact, target: target))
        }

        if r.isThermallyLimited {
            let detail = r.cpuSpeedLimit.flatMap { $0 < 100 ? "CPU limited to \($0)%" : nil } ?? "the system is throttling"
            add("thermal", "Mac is hot: \(detail). Close heavy apps and let it cool.", 95)
        } else if r.thermal == .fair {
            add("thermal", "Mac is warming up. Heavy work now may get throttled.", 50)
        }
        if r.swapGrowing && r.memory.pressure >= .warn {
            add("swap", "Memory is swapping to disk and growing. Close the biggest apps below.", 80)
        } else if r.memory.pressure >= .warn {
            add("pressure", "Memory pressure is high, so macOS compresses and swaps. Close what you are not using.", 65)
        }
        if let used = r.diskUsedPercent, used >= diskWarnUsed {
            add("disk", "Disk is \(LoadFormat.percent(used)) full. Free space so macOS can cache and swap.", 70)
        }
        let spotlight = processes.filter { isSpotlight($0.name) }
        let spotlightCPU = spotlight.reduce(0.0) { $0 + $1.cpuPercent }
        if spotlightCPU >= Self.spotlightCPU, let worst = spotlight.max(by: { $0.cpuPercent < $1.cpuPercent }) {
            add("spotlight", "Spotlight is indexing (\(LoadFormat.percent(spotlightCPU)) CPU). It settles on its own.", 60,
                .process(pid: worst.pid))
        }
        var apps: [String: (bytes: UInt64, biggest: ProcessUsage)] = [:]
        let pressured = r.memory.pressure >= .warn || r.swapGrowing || r.memory.usedFraction >= 0.85
        for process in processes where pressured && process.pid != selfPid && !process.isSystem && process.family != ResourceDiagnosis.mcpFamily {
            let entry = apps[process.name]
            let biggest = entry.map { $0.biggest.residentBytes >= process.residentBytes ? $0.biggest : process } ?? process
            apps[process.name] = ((entry?.bytes ?? 0) + process.residentBytes, biggest)
        }
        let big = apps.filter { $0.value.bytes >= bigAppBytes }.sorted {
            $0.value.bytes != $1.value.bytes ? $0.value.bytes > $1.value.bytes : $0.key < $1.key
        }.prefix(2)
        for (name, entry) in big {
            let gib = Double(entry.bytes) / Double(1024 * 1024 * 1024)
            add("app-\(name)", "\(name) uses \(LoadFormat.bytes(entry.bytes)). Quitting it frees that memory.",
                min(75, 30 + Int(gib * 10)), .process(pid: entry.biggest.pid))
        }
        let hot = processes.filter { $0.isSystem && !isSpotlight($0.name) && $0.cpuPercent > systemProcessCPU }
            .sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.pid < $1.pid }.prefix(2)
        for process in hot {
            add("system-\(process.pid)",
                "\(process.name) is using \(LoadFormat.percent(process.cpuPercent)) CPU; it is a system or managed process you cannot quit from here.",
                min(70, 40 + Int(process.cpuPercent / 10)))
        }
        let idle = agentSwarms.filter(\.isIdle)
        let idleBytes = idle.reduce(UInt64(0)) { $0 + $1.residentBytes }
        if let biggest = idle.first, idleBytes >= idleSwarmMinBytes {
            let members = idle.reduce(0) { $0 + $1.count }
            let gib = Double(idleBytes) / Double(1024 * 1024 * 1024)
            let text = idle.count == 1
                ? "\(biggest.identity.label) is idle but holds \(LoadFormat.agentSwarmTitle(biggest)), \(LoadFormat.bytes(idleBytes)). Close the session to free them."
                : "\(idle.count) idle sessions hold \(members) processes, \(LoadFormat.bytes(idleBytes)). Close the ones you are done with."
            add("idle-agents", text, min(75, 30 + Int(gib * 15)),
                .agent(pid: biggest.agentPid, sessionId: biggest.identity.sessionId))
        }
        if r.lowPowerMode { add("lowpower", "Low Power Mode is on and slows the CPU. Turn it off in System Settings, Battery.", 35) }
        if let me = processes.first(where: { $0.pid == selfPid }) ?? topCPU.first(where: { $0.pid == selfPid })
            ?? topMemory.first(where: { $0.pid == selfPid }) {
            let cpuRank = topCPU.prefix(3).contains { $0.pid == selfPid }
            let memoryRank = topMemory.prefix(3).contains { $0.pid == selfPid }
            if (cpuRank && me.cpuPercent >= selfCPU) || (memoryRank && me.residentBytes >= selfBytes) {
                add("self", "HerdNotch itself uses \(LoadFormat.percent(me.cpuPercent)) CPU and \(LoadFormat.bytes(me.residentBytes)). Close the panel when you do not need it.", 45)
            }
        }
        return out.sorted { $0.impact != $1.impact ? $0.impact > $1.impact : $0.id < $1.id }
    }
}

extension LoadFormat {
    /// "9 MCP processes" when every member is one, else "12 processes".
    public static func agentSwarmTitle(_ swarm: AgentSwarm) -> String {
        let noun = swarm.count == 1 ? "process" : "processes"
        return swarm.mcpCount == swarm.count ? "\(swarm.count) MCP \(noun)" : "\(swarm.count) \(noun)"
    }
}
