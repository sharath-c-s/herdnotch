import Combine
import Darwin
import Foundation
import NotchCore

enum SystemAlert: Equatable {
    case memoryPressureCritical
    /// Free space as a whole percent of the volume.
    case diskLow(freePercent: Int)
    case cpuSustained
}

/// Samples memory pressure, disk space and CPU every 30 s, only while at least one alert is enabled.
///
/// Each alert fires once per episode through a ``SustainedGate`` and re-arms after recovery, so a persistent
/// condition does not toast every sample.
@MainActor
final class SystemAlertMonitor: ObservableObject {
    let events = PassthroughSubject<SystemAlert, Never>()

    private(set) var memoryEnabled = false
    private(set) var diskEnabled = false
    private(set) var cpuEnabled = false

    private let interval: TimeInterval
    private let diskFreeThresholdPercent: Double
    private var memoryGate: SustainedGate
    private var diskGate: SustainedGate
    private var cpuGate: SustainedGate
    private var timer: DispatchSourceTimer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    init(
        interval: TimeInterval = 30, memoryCriticalLevel: Int = 4, diskFreeThresholdPercent: Double = 10,
        cpuPercent: Double = 90, cpuSustainedSeconds: TimeInterval = 120
    ) {
        self.interval = interval
        self.diskFreeThresholdPercent = diskFreeThresholdPercent
        memoryGate = SustainedGate(threshold: Double(memoryCriticalLevel) - 0.5, duration: 0, hysteresis: 0.5)
        diskGate = SustainedGate(threshold: 100 - diskFreeThresholdPercent, duration: 0, hysteresis: 2)
        cpuGate = SustainedGate(threshold: cpuPercent, duration: cpuSustainedSeconds, hysteresis: 5)
    }

    deinit { timer?.cancel() }

    func setEnabled(memory: Bool, disk: Bool, cpu: Bool) {
        memoryEnabled = memory
        diskEnabled = disk
        cpuEnabled = cpu
        if memory || disk || cpu { startIfNeeded() } else { stop() }
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        lastTicks = Self.cpuTicks()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample(now: Date()) }
        }
        timer = source
        source.resume()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        lastTicks = nil
    }

    private func sample(now: Date) {
        if memoryEnabled, let level = Self.memoryPressureLevel(),
            memoryGate.update(value: Double(level), now: now) {
            events.send(.memoryPressureCritical)
        }
        if diskEnabled, let free = Self.diskFreePercent(),
            diskGate.update(value: 100 - free, now: now) {
            events.send(.diskLow(freePercent: Int(free.rounded())))
        }
        if cpuEnabled, let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                let usage = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total) * 100
                if cpuGate.update(value: usage, now: now) { events.send(.cpuSustained) }
            }
            lastTicks = ticks
        }
    }

    nonisolated private static func memoryPressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    nonisolated private static func diskFreePercent() -> Double? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return Double(free) / Double(total) * 100
    }

    /// Cumulative busy and total ticks summed over all cores.
    nonisolated private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
            == KERN_SUCCESS, let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[cpu * states + Int(state)])) }
            let idle = tick(CPU_STATE_IDLE)
            let all = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + tick(CPU_STATE_NICE) + idle
            total += all
            busy += all - idle
        }
        return (busy, total)
    }
}
