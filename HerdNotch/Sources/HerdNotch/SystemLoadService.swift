import Darwin
import Foundation
import HerdKit
import NotchCore

/// CPU, memory and, when the Mac struggles, a plain resource diagnosis for the System page.
///
/// Runs only while some display is expanded on the System page (`NotchWindowController` calls
/// ``setActive(_:)`` on every presentation and page change), so a closed panel costs nothing. All sampling
/// happens on a private serial queue; the main actor only receives small value results.
@MainActor
final class SystemLoadService: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memory: MemoryReading?
    @Published private(set) var diagnosis: Diagnosis?

    private var timer: DispatchSourceTimer?
    private var sampler: Sampler?

    /// Idempotent: starts the timer when `active` turns on, cancels it and clears the readings when it turns off.
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let sampler = Sampler()
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
        } else {
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            sampler = nil
            cpuPercent = nil
            memory = nil
            diagnosis = nil
        }
    }

    /// Drops a result that was already in flight when the sampler was stopped or replaced.
    private func apply(_ result: Sampler.Result, from source: Sampler) {
        guard sampler === source else { return }
        if cpuPercent != result.cpuPercent { cpuPercent = result.cpuPercent }
        if memory != result.memory { memory = result.memory }
        if diagnosis != result.diagnosis { diagnosis = result.diagnosis }
    }
}

/// Confined to its own serial ``queue``; every stored property is touched only from there.
private final class Sampler: @unchecked Sendable {
    struct Result: Sendable {
        var cpuPercent: Double
        var memory: MemoryReading
        var diagnosis: Diagnosis?
    }

    let queue = DispatchQueue(label: "HerdNotch.SystemLoad", qos: .utility)

    private var previousTicks: CPUTicks?
    private var swapHistory = SwapHistory()
    private var hold = DiagnosisHold()
    private var previousProcesses: [Int32: ProcessSample]?
    private var previousScan: UInt64 = 0
    private let inspector = DarwinProcessInspector()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init() {
        previousTicks = Self.readTicks()
    }

    func tick() -> Result {
        let ticks = Self.readTicks()
        var cpu = 0.0
        if let previousTicks, let ticks { cpu = CPUTicks.cpuPercent(from: previousTicks, to: ticks) }
        previousTicks = ticks ?? previousTicks
        let memory = Self.readMemory()
        let start = DispatchTime.now().uptimeNanoseconds
        let baseline = swapHistory.baseline(recording: memory.swapUsedBytes, now: start)

        let fresh = ResourceDiagnosis.trigger(cpuPercent: cpu, memory: memory, swapBaseline: baseline)
        // While a diagnosis is held, keep scanning so its lists stay current and a re-trigger has a baseline.
        guard let reason = fresh ?? hold.current?.reason else {
            previousProcesses = nil
            _ = hold.update(nil, now: start)
            return Result(cpuPercent: cpu, memory: memory, diagnosis: nil)
        }
        // ponytail: with no earlier scan this blocks the sampler queue 1 s for a CPU baseline; keep a cheap rolling scan if that lag matters.
        if previousProcesses == nil {
            previousProcesses = scan()
            previousScan = DispatchTime.now().uptimeNanoseconds
            Thread.sleep(forTimeInterval: 1)
        }
        let current = scan()
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = Double(now &- previousScan) / 1_000_000_000
        let usage = ResourceDiagnosis.processCPU(
            previous: previousProcesses ?? [:], current: Array(current.values), interval: interval)
        previousProcesses = current
        previousScan = now
        let diagnosis = ResourceDiagnosis.diagnose(
            reason: reason, cpuPercent: cpu, memory: memory, processes: usage,
            cores: ProcessInfo.processInfo.activeProcessorCount)
        let shown = hold.update(fresh == nil ? nil : diagnosis, now: now)
        return Result(cpuPercent: cpu, memory: memory, diagnosis: shown == nil ? nil : diagnosis)
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

    /// Same-user processes only: `proc_pidinfo` refuses root-owned ones without privileges.
    private func scan() -> [Int32: ProcessSample] {
        var samples: [Int32: ProcessSample] = [:]
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
            samples[pid] = ProcessSample(
                pid: pid, name: name, family: ResourceDiagnosis.family(name: name, argv: argv),
                cpuTimeNs: ns, residentBytes: info.pti_resident_size)
        }
        return samples
    }
}
