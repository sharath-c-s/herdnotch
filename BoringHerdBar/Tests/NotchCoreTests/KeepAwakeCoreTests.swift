import Testing

@testable import NotchCore

@Suite struct KeepAwakeCoreTests {
    private func busyCore(working: Bool) -> KeepAwakeCore {
        var core = KeepAwakeCore()
        core.setConditions(KeepAwakeConditions(anyAgentWorking: true))
        core.setInputs(KeepAwakeInputs(anyAgentWorking: working), batteryPercent: nil)
        return core
    }

    private func setWorking(_ working: Bool, _ core: inout KeepAwakeCore) {
        core.setInputs(KeepAwakeInputs(anyAgentWorking: working), batteryPercent: nil)
    }

    @Test func conditionHoldsWithoutManual() {
        let core = busyCore(working: true)
        #expect(core.shouldHold)
        #expect(!core.manualOn)
        #expect(core.acquireAutoOffMinutes == nil)
    }

    @Test func manualOffSnoozesTheConditionUntilItNextEvaluatesFalse() {
        var core = busyCore(working: true)

        core.toggleManual(holding: true, preferredMinutes: 30)
        #expect(!core.shouldHold)
        #expect(core.conditionsSnoozed)

        // Agent keeps working and other inputs change: still snoozed.
        core.setInputs(KeepAwakeInputs(anyAgentWorking: true, onCharger: true), batteryPercent: 50)
        #expect(!core.shouldHold)

        // Agent stops, then a new working episode holds again.
        setWorking(false, &core)
        #expect(!core.conditionsSnoozed)
        #expect(!core.shouldHold)
        setWorking(true, &core)
        #expect(core.shouldHold)
    }

    @Test func manualOffWithNoConditionHoldingDoesNotSnooze() {
        var core = busyCore(working: false)
        core.setManual(on: true, minutes: nil)
        core.setManual(on: false, minutes: nil)
        #expect(!core.conditionsSnoozed)
        setWorking(true, &core)
        #expect(core.shouldHold)
    }

    @Test func toggleWhileNotHoldingTurnsManualOnWithThePreferredTimer() {
        var core = KeepAwakeCore()
        core.toggleManual(holding: false, preferredMinutes: 60)
        #expect(core.manualOn)
        #expect(core.manualMinutes == 60)
        #expect(core.acquireAutoOffMinutes == 60)
    }

    @Test func manualOnClearsTheSnooze() {
        var core = busyCore(working: true)
        core.setManual(on: false, minutes: nil)
        core.setManual(on: true, minutes: nil)
        #expect(!core.conditionsSnoozed)
        #expect(core.shouldHold)
    }

    @Test func timerEndWhileAConditionHoldsKeepsHoldingAndTouchesNoLid() {
        var core = busyCore(working: true)
        core.lidModeEnabled = true
        core.setManual(on: true, minutes: 15)
        let lidBefore = core.wantsLid(assertionActive: true, lidSetUp: true)

        let keepHeld = core.manualTimerEnded()

        #expect(keepHeld)
        #expect(core.shouldHold)
        #expect(!core.manualOn)
        #expect(core.wantsLid(assertionActive: true, lidSetUp: true) == lidBefore)
        #expect(lidBefore)
    }

    @Test func timerEndWithNoConditionReleases() {
        var core = KeepAwakeCore()
        core.setManual(on: true, minutes: 15)
        let keepHeld = core.manualTimerEnded()
        #expect(!keepHeld)
        #expect(!core.shouldHold)
    }

    @Test func externalReleaseWhileAConditionHoldsSnoozesIt() {
        var core = busyCore(working: true)
        core.adoptExternal(active: false)
        #expect(!core.shouldHold)
        #expect(core.conditionsSnoozed)
    }

    @Test func lidWantNeedsAssertionEnabledSetupAndBattery() {
        var core = KeepAwakeCore()
        core.lidModeEnabled = true
        core.setInputs(KeepAwakeInputs(), batteryPercent: 15, lidCutoff: 20)
        #expect(!core.wantsLid(assertionActive: true, lidSetUp: true))
        core.setInputs(KeepAwakeInputs(onCharger: true), batteryPercent: 15, lidCutoff: 20)
        #expect(core.wantsLid(assertionActive: true, lidSetUp: true))
        #expect(!core.wantsLid(assertionActive: false, lidSetUp: true))
        #expect(!core.wantsLid(assertionActive: true, lidSetUp: false))
    }

    @Test func shutdownClearsTheManualLayer() {
        var core = KeepAwakeCore()
        core.setManual(on: true, minutes: 15)
        core.shutdown()
        #expect(!core.manualOn)
        #expect(!core.shouldHold)
    }
}
