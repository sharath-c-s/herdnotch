import Darwin
import Foundation
import HerdKit
import NotchCore

/// How much the load sampler measures: nothing, the cheap CPU + memory summary (System page), or the full
/// Health scan (process table, thermal, disk, load average).
enum SystemLoadMode: Equatable {
    case off, summary, full
}

/// CPU and memory for the System page's summary line, plus the full ``HealthReport`` for the Health page.
///
/// Runs only while some display is expanded on the System (summary) or Health (full) page;
/// `NotchWindowController` calls ``setMode(_:)`` on every presentation and page change, so a closed panel
/// costs nothing. All sampling happens on a private serial queue; the main actor only receives small value
/// results and republishes only what changed.
@MainActor
final class SystemLoadService: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memory: MemoryReading?
    /// Full mode only: every reading, available from the first tick.
    @Published private(set) var readings: HealthReadings?
    /// Full mode only: `nil` until a second process scan gives CPU deltas (about 2 s after the page opens).
    @Published private(set) var report: HealthReport?

    private var mode = SystemLoadMode.off
    private var timer: DispatchSourceTimer?
    private var sampler: Sampler?
    private let externalAgents = LockedBox<[Int32: AgentIdentity]>([:])

    /// Idempotent: a changed mode stops the old sampler and starts the new one; `.off` clears every reading.
    func setMode(_ newMode: SystemLoadMode) {
        guard newMode != mode else { return }
        mode = newMode
        timer?.cancel()
        timer = nil
        sampler = nil
        if newMode == .off || newMode == .summary {
            readings = nil
            report = nil
        }
        guard newMode != .off else {
            cpuPercent = nil
            memory = nil
            return
        }
        let sampler = Sampler(full: newMode == .full, externalAgents: externalAgents)
        self.sampler = sampler
        let timer = DispatchSource.makeTimerSource(queue: sampler.queue)
        // First fire early so the page fills quickly; the baseline ticks are read when the sampler is made.
        timer.schedule(deadline: .now() + 0.5, repeating: 2.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let result = sampler.tick()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result, from: sampler) }
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Pid to agent name for agents the Claude session registry does not know (Codex), from the herd snapshot.
    func setExternalAgents(_ agents: [Int32: AgentIdentity]) {
        externalAgents.value = agents
    }

    /// Drops a result that was already in flight when the sampler was stopped or replaced.
    private func apply(_ result: Sampler.Result, from source: Sampler) {
        guard sampler === source else { return }
        if cpuPercent != result.cpuPercent { cpuPercent = result.cpuPercent }
        if memory != result.memory { memory = result.memory }
        if readings != result.readings { readings = result.readings }
        if report != result.report { report = result.report }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Confined to its own serial ``queue``; every stored property is touched only from there.
private final class Sampler: @unchecked Sendable {
    struct Result: Sendable {
        var cpuPercent: Double
        var memory: MemoryReading
        var readings: HealthReadings?
        var report: HealthReport?
    }

    let queue = DispatchQueue(label: "HerdNotch.SystemLoad", qos: .utility)

    private let full: Bool
    private let externalAgents: LockedBox<[Int32: AgentIdentity]>
    private var previousTicks: CPUTicks?
    private var swapHistory = SwapHistory()
    private var previousProcesses: [Int32: ProcessSample]?
    private var previousScan: UInt64 = 0
    private let inspector = DarwinProcessInspector()
    private let registry = ClaudeSessionRegistry()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private var thermal = ProcessInfo.processInfo.thermalState
    private var thermalObserver: NSObjectProtocol?
    private var speedLimit: Int?
    private var lastPmset: UInt64 = 0
    private var diskUsedPercent: Double?
    private var lastDisk: UInt64 = 0
    private var registryAgents: [Int32: AgentIdentity] = [:]
    private var lastRegistry: UInt64 = 0
    private var psEntries: [PsEntry] = []
    private var lastPs: UInt64 = 0

    /// Process-wide, so a fresh sampler (fast Health and System switching) cannot start a second probe while one runs.
    private static let pmsetInFlight = InFlightFlag()
    private static let psInFlight = InFlightFlag()
    private static let pmsetEveryNs: UInt64 = 10 * 1_000_000_000
    private static let psEveryNs: UInt64 = 4 * 1_000_000_000
    private static let diskEveryNs: UInt64 = 30 * 1_000_000_000

    init(full: Bool, externalAgents: LockedBox<[Int32: AgentIdentity]>) {
        self.full = full
        self.externalAgents = externalAgents
        previousTicks = Self.readTicks()
        if full {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                queue.async { self.thermal = ProcessInfo.processInfo.thermalState }
            }
        }
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func tick() -> Result {
        let ticks = Self.readTicks()
        var cpu = 0.0
        if let previousTicks, let ticks { cpu = CPUTicks.cpuPercent(from: previousTicks, to: ticks) }
        previousTicks = ticks ?? previousTicks
        let memory = Self.readMemory()
        guard full else { return Result(cpuPercent: cpu, memory: memory) }

        let start = DispatchTime.now().uptimeNanoseconds
        let baseline = swapHistory.baseline(recording: memory.swapUsedBytes, now: start)
        refreshSlowReadings(now: start)
        var load = [Double](repeating: 0, count: 1)
        if getloadavg(&load, 1) < 1 { load[0] = 0 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let readings = HealthReadings(
            cpuPercent: cpu, loadAverage: load[0], cores: cores, memory: memory,
            swapGrowing: ResourceDiagnosis.isSwapGrowing(swap: memory.swapUsedBytes, baseline: baseline),
            diskUsedPercent: diskUsedPercent, thermal: Self.level(thermal), cpuSpeedLimit: speedLimit,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)

        let (current, scannedTable) = scan()
        var table = scannedTable
        let scanned = Set(current.keys)
        let now = DispatchTime.now().uptimeNanoseconds
        defer {
            previousProcesses = current
            previousScan = now
        }
        // The first scan has no earlier one to difference against; readings show now, the report follows.
        guard let previous = previousProcesses else { return Result(cpuPercent: cpu, memory: memory, readings: readings) }
        let interval = Double(now &- previousScan) / 1_000_000_000
        var usage = ResourceDiagnosis.processCPU(previous: previous, current: Array(current.values), interval: interval)
        let unreadable = PsTable.usages(psEntries, excluding: scanned, currentUid: getuid(), selfPid: getpid())
        usage += unreadable
        for process in unreadable { table[process.pid] = ProcessNode(parentPid: process.parentPid, name: process.name) }
        let report = HealthReport.build(
            readings: readings, processes: usage, table: table, agents: agents(), selfPid: getpid())
        return Result(cpuPercent: cpu, memory: memory, readings: readings, report: report)
    }

    // MARK: - Slow readings

    private func refreshSlowReadings(now: UInt64) {
        if now &- lastPmset >= Self.pmsetEveryNs, Self.pmsetInFlight.begin() {
            lastPmset = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let output = try? BlockingProcess.run("/usr/bin/pmset", ["-g", "therm"], timeout: 2)
                let limit = output?.succeeded == true ? output.flatMap { PmsetTherm.cpuSpeedLimit($0.stdout) } : nil
                Self.pmsetInFlight.end()
                guard let self else { return }
                queue.async { self.speedLimit = limit }
            }
        }
        if now &- lastPs >= Self.psEveryNs, Self.psInFlight.begin() {
            lastPs = now
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let output = try? BlockingProcess.run("/bin/ps", PsTable.arguments, timeout: 2)
                let entries = output?.succeeded == true ? output.map { PsTable.parse($0.stdout) } : nil
                Self.psInFlight.end()
                guard let self else { return }
                queue.async { if let entries { self.psEntries = entries } }
            }
        }
        if now &- lastDisk >= Self.diskEveryNs || diskUsedPercent == nil {
            lastDisk = now
            diskUsedPercent = Self.readDiskUsedPercent()
        }
        if now &- lastRegistry >= Self.pmsetEveryNs || lastRegistry == 0 {
            lastRegistry = now
            registryAgents = Dictionary(
                registry.liveEntries().map { entry in
                    let label = entry.name.isEmpty ? (entry.cwd as NSString).lastPathComponent : entry.name
                    return (entry.pid, AgentIdentity(label: label, sessionId: entry.sessionId, registryStatus: entry.status))
                }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func agents() -> [Int32: AgentIdentity] {
        registryAgents.merging(externalAgents.value) { registry, _ in registry }
    }

    private static func level(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    /// Plain free space (`volumeAvailableCapacityKey`), not the "important usage" key: that one makes macOS
    /// compute purgeable space across every cache-delete service and costs real CPU.
    /// Purgeable space is therefore not counted as free, so the Disk row can read fuller than Finder does.
    private static func readDiskUsedPercent() -> Double? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
            let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return min(100, max(0, 100 - Double(available) / Double(total) * 100))
    }

    // MARK: - Cheap readings

    private static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private static func readMemory() -> MemoryReading {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        // Activity Monitor's "Memory Used": app memory (internal minus purgeable) + wired + compressed.
        let appPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let pages = status == KERN_SUCCESS
            ? (appPages > purgeable ? appPages - purgeable : 0) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)
            : 0
        // host_page_size is the unit the vm counters use; the `vm_kernel_page_size` global is not concurrency-safe.
        var pageSizeValue: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeValue)
        let pageSize = UInt64(pageSizeValue)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        return MemoryReading(
            usedBytes: pages * pageSize, totalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: swapUsed, pressure: MemoryPressure(kernelLevel: Int(level)))
    }

    // MARK: - Process scan

    private static func footprint(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    /// Same-user processes only: `proc_pidinfo` refuses root-owned ones without privileges (`ps` covers those).
    /// Memory is the physical footprint (Activity Monitor's Memory column), which counts compressed and swapped
    /// pages that `pti_resident_size` leaves out.
    private func scan() -> (samples: [Int32: ProcessSample], table: [Int32: ProcessNode]) {
        var samples: [Int32: ProcessSample] = [:]
        var table: [Int32: ProcessNode] = [:]
        for pid in inspector.allPids() {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !name.isEmpty else { continue }
            let argv = ResourceDiagnosis.isInterpreter(name) ? inspector.argv(of: pid) : nil
            // Task times are mach absolute ticks, not nanoseconds, on Apple Silicon.
            let ticks = info.pti_total_user &+ info.pti_total_system
            let ns = ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            let parent = inspector.parentPid(of: pid) ?? 0
            samples[pid] = ProcessSample(
                pid: pid, name: name, family: ResourceDiagnosis.family(name: name, argv: argv),
                cpuTimeNs: ns, residentBytes: Self.footprint(of: pid) ?? info.pti_resident_size, parentPid: parent)
            table[pid] = ProcessNode(parentPid: parent, name: name, argv: argv)
        }
        return (samples, table)
    }
}

/// A lock-protected "one at a time" flag shared across sampler instances.
private final class InFlightFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func end() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
