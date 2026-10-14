import Foundation
import IOKit
import IOKit.ps
import NotchCore

/// Detailed battery readings (health, cycles, watts, time remaining) for the notch's power view.
///
/// Event-driven: refreshes on IOKit's power-source notification and on demand, with no timer. Amperage is
/// signed (negative while discharging) and the registry may hand it back as a wrapped unsigned value.
@MainActor
final class PowerInfoService: ObservableObject {
    struct Snapshot: Equatable {
        var healthPercent: Int?
        var cycleCount: Int?
        var watts: Double?
        var isCharging = false
        var onCharger = false
        var timeToEmptyMinutes: Int?
        var timeToFullMinutes: Int?
    }

    @Published private(set) var snapshot = Snapshot()

    /// Held for the process lifetime, like BatteryService's; never torn down.
    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let service = Unmanaged<PowerInfoService>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in service.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func refresh() {
        var next = Snapshot()
        let props = Self.smartBatteryProperties()
        func int(_ key: String) -> Int? { (props?[key] as? NSNumber)?.intValue }
        next.healthPercent = PowerFormat.healthPercent(
            rawMaxCapacity: int("AppleRawMaxCapacity"), designCapacity: int("DesignCapacity"))
        next.cycleCount = int("CycleCount")
        next.isCharging = props?["IsCharging"] as? Bool ?? false
        next.onCharger = props?["ExternalConnected"] as? Bool ?? false
        if let amp = props?["Amperage"] as? NSNumber, let volt = int("Voltage") {
            next.watts = PowerFormat.watts(amperageMA: Int(Int64(bitPattern: amp.uint64Value)), voltageMV: volt)
        }
        let times = Self.powerSourceTimes()
        next.timeToEmptyMinutes = times.toEmpty
        next.timeToFullMinutes = times.toFull
        if next != snapshot { snapshot = next }
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }

    /// IOKit reports -1 while it is still calculating; that maps to `nil` here.
    private static func powerSourceTimes() -> (toEmpty: Int?, toFull: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            func minutes(_ key: String) -> Int? {
                guard let value = desc[key] as? Int, value >= 0 else { return nil }
                return value
            }
            return (minutes(kIOPSTimeToEmptyKey), minutes(kIOPSTimeToFullChargeKey))
        }
        return (nil, nil)
    }
}
