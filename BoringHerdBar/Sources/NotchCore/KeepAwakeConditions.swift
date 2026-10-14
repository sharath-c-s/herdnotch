import Foundation

/// A snapshot of everything ``KeepAwakeConditions`` can look at. The integration layer builds it; nothing
/// here reads the system.
public struct KeepAwakeInputs: Sendable, Equatable {
    public var manualOn: Bool
    public var anyAgentWorking: Bool
    public var runningBundleIds: Set<String>
    public var onCharger: Bool
    public var externalDisplay: Bool

    public init(
        manualOn: Bool = false, anyAgentWorking: Bool = false, runningBundleIds: Set<String> = [],
        onCharger: Bool = false, externalDisplay: Bool = false
    ) {
        self.manualOn = manualOn
        self.anyAgentWorking = anyAgentWorking
        self.runningBundleIds = runningBundleIds
        self.onCharger = onCharger
        self.externalDisplay = externalDisplay
    }
}

/// Which automatic keep-awake conditions are enabled. Enabled conditions are OR-combined with the manual toggle.
public struct KeepAwakeConditions: Sendable, Equatable {
    public var anyAgentWorking: Bool
    public var appRunningBundleIds: Set<String>
    public var onCharger: Bool
    public var externalDisplay: Bool

    public init(
        anyAgentWorking: Bool = false, appRunningBundleIds: Set<String> = [], onCharger: Bool = false,
        externalDisplay: Bool = false
    ) {
        self.anyAgentWorking = anyAgentWorking
        self.appRunningBundleIds = appRunningBundleIds
        self.onCharger = onCharger
        self.externalDisplay = externalDisplay
    }

    /// An empty `appRunningBundleIds` means the app condition is disabled, never "matches anything".
    public func shouldHold(_ inputs: KeepAwakeInputs) -> Bool {
        if inputs.manualOn { return true }
        if anyAgentWorking && inputs.anyAgentWorking { return true }
        if !appRunningBundleIds.isDisjoint(with: inputs.runningBundleIds) { return true }
        if onCharger && inputs.onCharger { return true }
        if externalDisplay && inputs.externalDisplay { return true }
        return false
    }

    /// Lid-closed mode drains a closed, bagged laptop, so it is refused at or below `cutoff` percent on battery.
    /// On the charger the cutoff does not apply.
    public static func lidModeAllowed(batteryPercent: Int, onCharger: Bool, cutoff: Int = 20) -> Bool {
        onCharger || batteryPercent > cutoff
    }
}
