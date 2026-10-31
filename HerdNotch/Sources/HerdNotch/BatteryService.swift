import Foundation
import IOKit.ps

/// The Mac's internal-battery state (charge percentage + whether it is charging), for the notch's utility
/// band. Event-driven via IOKit's power-source run-loop notification — it updates only when the power state
/// actually changes, so there is no perpetual timer and no idle-CPU cost, unlike a polled reading.
///
/// On a desktop Mac with no internal battery, ``percent`` stays `nil` and ``hasBattery`` is `false`; the UI
/// hides the indicator entirely in that case rather than showing a meaningless value.
///
/// `@MainActor`, matching the other notch services: every published property is read by SwiftUI on the main
/// actor. The IOKit callback is a C function pointer (no captured state), which hops back onto the main actor
/// before touching `self`.
@MainActor
final class BatteryService: ObservableObject {
    /// Current charge as a whole-number percentage 0...100, or `nil` when this Mac has no internal battery.
    @Published private(set) var percent: Int?

    /// Whether the battery is currently charging (plugged in and not yet full).
    @Published private(set) var isCharging: Bool = false

    /// True when this Mac has an internal battery worth showing an indicator for.
    var hasBattery: Bool { percent != nil }

    /// The retained run-loop source for IOKit's power-source-changed notification, held for the process
    /// lifetime (this service is built once by `NotchWindowController`); never torn down.
    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The callback is a bare C function pointer, so it can capture nothing; it recovers `self` from the
        // opaque context pointer and hops to the main actor. IOKit posts this whenever any power source
        // changes — plug/unplug, a percentage tick, charge completing — which is exactly the set of moments
        // the indicator needs to update, with no timer of our own.
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in service.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    /// Re-reads the internal battery's charge and charging state from IOKit. Called on init and on every
    /// power-source-changed notification.
    func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            percent = nil
            return
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any]
            else { continue }
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            // For the internal battery IOKit reports CurrentCapacity already as a 0...100 percentage with a
            // MaxCapacity of 100, but compute the ratio defensively in case a future OS reports raw mAh.
            percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            isCharging = charging
            return
        }
        percent = nil
    }
}
