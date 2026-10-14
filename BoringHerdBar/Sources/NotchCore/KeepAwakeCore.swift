import Foundation

/// The keep-awake decision state machine: a manual layer, the automatic conditions, and a snooze that lets a
/// manual "off" beat a condition that is still true. Pure; the service owns the assertion and the lid.
public struct KeepAwakeCore: Equatable, Sendable {
    /// The user's manual choice, distinct from whether the assertion is held for an automatic reason.
    public private(set) var manualOn = false
    /// Auto-off for a manual hold: `nil` means until turned off.
    public private(set) var manualMinutes: Int?
    /// Set by a manual off while a condition still holds; cleared when the conditions next evaluate false.
    public private(set) var conditionsSnoozed = false
    public private(set) var conditions = KeepAwakeConditions()
    public private(set) var inputs = KeepAwakeInputs()
    public private(set) var batteryPercent: Int?
    public private(set) var lidCutoff = 20
    public var lidModeEnabled = false

    public init() {}

    /// Whether the conditions alone (ignoring manual and snooze) call for a hold.
    public var conditionsHold: Bool { conditions.shouldHold(inputs) }

    public var shouldHold: Bool { manualOn || (!conditionsSnoozed && conditionsHold) }

    /// The auto-off to arm when acquiring now: only a manual hold takes a timer.
    public var acquireAutoOffMinutes: Int? { manualOn ? manualMinutes : nil }

    public mutating func setConditions(_ conditions: KeepAwakeConditions) {
        self.conditions = conditions
        clearSnoozeIfConditionsFell()
    }

    /// `inputs.manualOn` is ignored: the core owns the manual layer.
    public mutating func setInputs(_ inputs: KeepAwakeInputs, batteryPercent: Int?, lidCutoff: Int = 20) {
        var own = inputs
        own.manualOn = false
        self.inputs = own
        self.batteryPercent = batteryPercent
        self.lidCutoff = lidCutoff
        clearSnoozeIfConditionsFell()
    }

    public mutating func setManual(on: Bool, minutes: Int?) {
        manualOn = on
        manualMinutes = on ? minutes : nil
        // Snooze only what would otherwise keep holding; turning on makes the manual layer authoritative again.
        conditionsSnoozed = on ? false : conditionsHold
    }

    /// Off while the assertion is held (whatever the reason), otherwise on with `preferredMinutes`.
    public mutating func toggleManual(holding: Bool, preferredMinutes: Int?) {
        setManual(on: !holding, minutes: holding ? nil : preferredMinutes)
    }

    /// The manual auto-off elapsed. Ends only the manual layer; returns whether a condition still holds, so
    /// the caller keeps the assertion without releasing it.
    public mutating func manualTimerEnded() -> Bool {
        manualOn = false
        manualMinutes = nil
        return shouldHold
    }

    /// The assertion changed behind the core's back (a release or acquire it did not ask for).
    public mutating func adoptExternal(active: Bool) {
        manualOn = active
        manualMinutes = nil
        conditionsSnoozed = active ? false : conditionsHold
    }

    public mutating func shutdown() {
        manualOn = false
        manualMinutes = nil
    }

    /// Lid-closed mode is wanted only while the assertion is held, enabled, set up, and the battery allows it.
    public func wantsLid(assertionActive: Bool, lidSetUp: Bool) -> Bool {
        let allowed = KeepAwakeConditions.lidModeAllowed(
            batteryPercent: batteryPercent ?? 100, onCharger: inputs.onCharger, cutoff: lidCutoff)
        return assertionActive && lidModeEnabled && allowed && lidSetUp
    }

    private mutating func clearSnoozeIfConditionsFell() {
        if conditionsSnoozed, !conditionsHold { conditionsSnoozed = false }
    }
}
