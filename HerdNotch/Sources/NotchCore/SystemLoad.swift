import Foundation

/// Cumulative CPU ticks across all cores, as `host_statistics(HOST_CPU_LOAD_INFO)` reports them.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share of the tick delta, 0 to 100 for the whole machine. The kernel counters are 32-bit and
    /// wrap, so deltas use wrapping subtraction; a zero delta reads as 0 rather than dividing by zero.
    public static func cpuPercent(from previous: CPUTicks, to current: CPUTicks) -> Double {
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let nice = Double(current.nice &- previous.nice)
        let idle = Double(current.idle &- previous.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, busy / total * 100))
    }
}

public enum MemoryPressure: Int, Equatable, Comparable, Sendable {
    case normal, warn, critical

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Maps `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical); anything unknown is normal.
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warn
        default: self = .normal
        }
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure

    public init(usedBytes: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    /// Used share of physical memory, clamped to 0...1.
    public var usedFraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(usedBytes) / Double(totalBytes))) : 0
    }
}

/// One process at one instant: cumulative CPU time and resident size.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var family: String
    public var cpuTimeNs: UInt64
    public var residentBytes: UInt64

    public init(pid: Int32, name: String, family: String, cpuTimeNs: UInt64, residentBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.family = family
        self.cpuTimeNs = cpuTimeNs
        self.residentBytes = residentBytes
    }
}

/// A process with its CPU over the last interval; 100 means one full core (Activity Monitor's convention).
public struct ProcessUsage: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var family: String
    public var cpuPercent: Double
    public var residentBytes: UInt64

    public init(pid: Int32, name: String, family: String, cpuPercent: Double, residentBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.family = family
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

/// Many small processes of one kind (for example MCP servers) that add up.
public struct Swarm: Equatable, Sendable {
    public var family: String
    public var count: Int
    public var cpuPercent: Double
    public var residentBytes: UInt64
}

public enum DiagnosisReason: Equatable, Sendable {
    case highCPU, swapping, memoryPressure
}

public struct Diagnosis: Equatable, Sendable {
    public var reason: DiagnosisReason
    public var topCPU: [ProcessUsage]
    public var topMemory: [ProcessUsage]
    public var swarms: [Swarm]
}

public enum ResourceDiagnosis {
    public static let cpuThreshold = 90.0
    public static let swapGrowthBytes: UInt64 = 64 * 1024 * 1024
    public static let swarmMinMembers = 5
    public static let swarmMinCPU = 10.0
    public static let swarmMinBytes: UInt64 = 1024 * 1024 * 1024
    public static let listLimit = 3
    public static let swapWindowNs: UInt64 = 30 * 1_000_000_000
    public static let holdNs: UInt64 = 10 * 1_000_000_000
    public static let mcpFamily = "MCP processes"
    public static let residualName = "System and other users"
    public static let residualPid: Int32 = -1

    /// Executable names whose argv is worth reading, because the real program is the first script argument.
    /// Case-insensitive: the framework build of Python reports itself as "Python".
    public static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["node", "uv", "uvx", "npx", "bun", "deno"].contains(name) || name.hasPrefix("python")
    }

    /// The executable name, or "MCP processes" when the name or any argument mentions `mcp`
    /// (`npx @x/mcp-server`, `uvx mcp-foo`, a native `foo-mcp` binary).
    public static func family(name: String, argv: [String]?) -> String {
        if name.lowercased().contains("mcp") { return mcpFamily }
        if let argv, argv.contains(where: { $0.lowercased().contains("mcp") }) { return mcpFamily }
        return name
    }

    /// Per-process CPU over `interval` seconds. A process missing from `previous`, or whose CPU time went
    /// backwards (pid reuse), reads 0 because there is no honest delta for it.
    public static func processCPU(previous: [Int32: ProcessSample], current: [ProcessSample], interval: Double) -> [ProcessUsage] {
        current.map { sample in
            var percent = 0.0
            if let before = previous[sample.pid], interval > 0, sample.cpuTimeNs >= before.cpuTimeNs {
                percent = Double(sample.cpuTimeNs - before.cpuTimeNs) / (interval * 1_000_000_000) * 100
            }
            return ProcessUsage(
                pid: sample.pid, name: sample.name, family: sample.family,
                cpuPercent: percent, residentBytes: sample.residentBytes)
        }
    }

    /// Why the machine is struggling, or `nil` when it is not. Cheap, so the sampler calls it before scanning processes.
    /// `swapBaseline` is the lowest swap reading of the last ``swapWindowNs`` (see ``SwapHistory``).
    /// When several triggers hold, the order is CPU, then swapping, then memory pressure.
    public static func trigger(cpuPercent: Double, memory: MemoryReading, swapBaseline: UInt64?) -> DiagnosisReason? {
        if cpuPercent >= cpuThreshold { return .highCPU }
        if let swapBaseline, memory.swapUsedBytes > swapBaseline, memory.swapUsedBytes - swapBaseline > swapGrowthBytes {
            return .swapping
        }
        if memory.pressure >= .warn { return .memoryPressure }
        return nil
    }

    public static func evaluate(
        cpuPercent: Double, memory: MemoryReading, swapBaseline: UInt64?, processes: [ProcessUsage], cores: Int = 1
    ) -> Diagnosis? {
        guard let reason = trigger(cpuPercent: cpuPercent, memory: memory, swapBaseline: swapBaseline) else { return nil }
        return diagnose(reason: reason, cpuPercent: cpuPercent, memory: memory, processes: processes, cores: cores)
    }

    /// Builds the lists for a known reason. The scan sees only same-user processes, so a residual row
    /// ("System and other users": machine total minus the visible sum, clamped at 0) joins the rankings.
    public static func diagnose(
        reason: DiagnosisReason, cpuPercent: Double, memory: MemoryReading, processes: [ProcessUsage], cores: Int
    ) -> Diagnosis {
        let visibleCPU = processes.reduce(0.0) { $0 + $1.cpuPercent }
        let visibleBytes = processes.reduce(UInt64(0)) { $0 &+ $1.residentBytes }
        let residual = ProcessUsage(
            pid: residualPid, name: residualName, family: residualName,
            cpuPercent: max(0, cpuPercent * Double(max(cores, 1)) - visibleCPU),
            residentBytes: memory.usedBytes > visibleBytes ? memory.usedBytes - visibleBytes : 0)
        let ranked = processes + [residual]
        let byCPU = ranked.sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return ($0.name, $0.pid) < ($1.name, $1.pid)
        }
        let byMemory = ranked.sorted {
            if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            return ($0.name, $0.pid) < ($1.name, $1.pid)
        }
        return Diagnosis(
            reason: reason,
            topCPU: Array(byCPU.prefix(listLimit)),
            topMemory: Array(byMemory.prefix(listLimit)),
            swarms: swarms(in: processes))
    }

    static func swarms(in processes: [ProcessUsage]) -> [Swarm] {
        var groups: [String: Swarm] = [:]
        for process in processes {
            var group = groups[process.family] ?? Swarm(family: process.family, count: 0, cpuPercent: 0, residentBytes: 0)
            group.count += 1
            group.cpuPercent += process.cpuPercent
            group.residentBytes += process.residentBytes
            groups[process.family] = group
        }
        return groups.values
            .filter { $0.count >= swarmMinMembers && ($0.cpuPercent >= swarmMinCPU || $0.residentBytes >= swarmMinBytes) }
            .sorted {
                if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
                return $0.family < $1.family
            }
            .prefix(listLimit).map { $0 }
    }
}

/// Recent swap readings, so growth is judged against the lowest value of the last 30 s rather than the previous
/// tick (which misses steady swapping and flickers on a burst).
public struct SwapHistory: Sendable {
    private var entries: [(time: UInt64, swap: UInt64)] = []

    public init() {}

    /// Lowest swap in the window before `swap`, or `nil` on the first reading; then records `swap`. `now` is in ns.
    public mutating func baseline(recording swap: UInt64, now: UInt64) -> UInt64? {
        entries.removeAll { now &- $0.time > ResourceDiagnosis.swapWindowNs }
        let lowest = entries.map(\.swap).min()
        entries.append((now, swap))
        return lowest
    }
}

/// Keeps the last diagnosis on screen for 10 s after its last trigger, so a brief dip does not blink it away.
public struct DiagnosisHold: Sendable {
    public private(set) var current: Diagnosis?
    private var lastTrigger: UInt64 = 0

    public init() {}

    /// A fresh diagnosis replaces the held one at once; `nil` keeps it until 10 s (inclusive) after its trigger.
    public mutating func update(_ fresh: Diagnosis?, now: UInt64) -> Diagnosis? {
        if let fresh {
            current = fresh
            lastTrigger = now
        } else if current != nil, now &- lastTrigger > ResourceDiagnosis.holdNs {
            current = nil
        }
        return current
    }
}

/// Display formatting for the System page's load lines. Pure value-in, string-out.
public enum LoadFormat {
    private static let gib = Double(1024 * 1024 * 1024)
    private static let mib = Double(1024 * 1024)

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "4.1 GB", or "512 MB" below one GiB.
    public static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= gib { return "\(gigabytes(value)) GB" }
        return "\(Int((value / mib).rounded())) MB"
    }

    /// "18.2 of 36 GB": one decimal, dropped when it is zero.
    public static func memory(used: UInt64, total: UInt64) -> String {
        "\(gigabytes(Double(used))) of \(gigabytes(Double(total))) GB"
    }

    public static func reason(_ reason: DiagnosisReason) -> String {
        switch reason {
        case .highCPU: "CPU above 90%"
        case .swapping: "Memory is swapping"
        case .memoryPressure: "Memory pressure high"
        }
    }

    /// "34 MCP processes", or "7 node" for any other family.
    public static func swarmTitle(_ swarm: Swarm) -> String {
        "\(swarm.count) \(swarm.family)"
    }

    private static func gigabytes(_ value: Double) -> String {
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value / gib)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
