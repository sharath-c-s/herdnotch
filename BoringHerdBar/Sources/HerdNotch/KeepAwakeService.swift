import Combine
import Foundation
import NotchCore

/// Combines the manual caffeinate toggle with automatic conditions and optional lid-closed mode.
///
/// A thin wrapper: ``KeepAwakeCore`` decides, this applies the decision to ``CaffeinateService`` (the only
/// owner of the IOPM assertion) and the lid controller. Every toggle goes through ``toggleManual()``; a change
/// made behind this service's back is mirrored into the core by comparing the assertion with what this service
/// last asked for. Condition holds take no auto-off timer.
@MainActor
final class KeepAwakeService: ObservableObject {
    let caffeinate: CaffeinateService
    let lid: LidSleepController

    /// The user's manual choice, distinct from whether the assertion is held for an automatic reason.
    @Published private(set) var manualOn = false
    @Published private(set) var lidModeEnabled = false
    @Published private(set) var lidActive = false

    /// Fires with the new state after a manual transition (toggle, timed hold, auto-off release), never for a
    /// condition-driven acquire or release.
    let manualChanges = PassthroughSubject<Bool, Never>()

    var isHolding: Bool { caffeinate.isActive }

    private var core = KeepAwakeCore()
    /// Whether the assertion should be held, as of this service's last decision. A difference from the live
    /// assertion means someone else changed it.
    private var expectedActive = false
    private var isShutDown = false
    private var cancellable: AnyCancellable?

    init(caffeinate: CaffeinateService, lid: LidSleepController) {
        self.caffeinate = caffeinate
        self.lid = lid
        cancellable = caffeinate.$isActive.dropFirst().sink { [weak self] _ in
            // Hop one main-actor turn: `@Published` fires before the new value is stored.
            Task { @MainActor in self?.adoptExternalChange() }
        }
        caffeinate.keepHeldOnAutoOff = { [weak self] in self?.manualTimerEnded() ?? false }
        lid.onResult = { [weak self] active, enableFailed in self?.lidApplied(active: active, enableFailed: enableFailed) }
    }

    /// Turns the assertion off if it is held (for any reason), else on with the default auto-off preference.
    /// A manual off snoozes any condition that still holds until it next evaluates false.
    func toggleManual() {
        let before = caffeinate.isActive
        core.toggleManual(holding: before, preferredMinutes: CaffeinateService.preferredAutoOffMinutes)
        applyManual(before: before)
    }

    /// Turns the manual hold on for `minutes` (`nil` = until turned off), or off.
    func setManual(on: Bool, minutes: Int?) {
        let before = caffeinate.isActive
        core.setManual(on: on, minutes: minutes)
        applyManual(before: before)
    }

    func setConditions(_ conditions: KeepAwakeConditions) {
        guard conditions != core.conditions else { return }
        core.setConditions(conditions)
        evaluate()
    }

    /// Fed by the integration layer; `manualOn` in `inputs` is ignored and replaced with the service's own.
    func setInputs(_ inputs: KeepAwakeInputs, batteryPercent: Int?, lidCutoff: Int = 20) {
        core.setInputs(inputs, batteryPercent: batteryPercent, lidCutoff: lidCutoff)
        evaluate()
    }

    func setLidMode(_ on: Bool) {
        guard on != core.lidModeEnabled else { return }
        core.lidModeEnabled = on
        evaluate()
    }

    /// Re-runs the decision, for state this service cannot observe itself (the sudoers rule being installed).
    func reevaluate() {
        evaluate()
    }

    /// Turns lid mode off and releases the assertion; later input changes no longer re-acquire it.
    func shutdown() {
        isShutDown = true
        core.shutdown()
        manualOn = false
        lid.shutdown()
        lidActive = false
        expectedActive = false
        caffeinate.releaseForShutdown()
    }

    private func applyManual(before: Bool) {
        if core.manualOn, caffeinate.isActive { caffeinate.setAutoOff(minutes: core.manualMinutes) }
        evaluate()
        if caffeinate.isActive != before { manualChanges.send(caffeinate.isActive) }
    }

    /// The manual auto-off fired. Ends the manual layer; `true` tells ``CaffeinateService`` to stay held
    /// because a condition still wants it. On `false` the expectation is left at "held", so the release that
    /// follows is adopted and reconciles the lid.
    private func manualTimerEnded() -> Bool {
        guard !isShutDown else { return false }
        let stillHolds = core.manualTimerEnded()
        if stillHolds { evaluate() }
        return stillHolds
    }

    /// An assertion change this service did not make: the auto-off timer releasing, or a toggle elsewhere.
    private func adoptExternalChange() {
        guard !isShutDown else { return }
        let actual = caffeinate.isActive
        guard actual != expectedActive else { return }
        expectedActive = actual
        core.adoptExternal(active: actual)
        evaluate()
        manualChanges.send(actual)
    }

    private func evaluate() {
        guard !isShutDown else { return }
        let hold = core.shouldHold
        expectedActive = hold
        if hold, !caffeinate.isActive {
            caffeinate.acquire(autoOffMinutes: core.acquireAutoOffMinutes)
        } else if !hold, caffeinate.isActive {
            caffeinate.release()
        }
        // The acquire may have failed; keep the expectation honest so a later release is not read as external.
        expectedActive = caffeinate.isActive
        lid.reconcile(want: core.wantsLid(assertionActive: caffeinate.isActive, lidSetUp: lid.isSetUp))
        if core.lidModeEnabled != lidModeEnabled { lidModeEnabled = core.lidModeEnabled }
        if core.manualOn != manualOn { manualOn = core.manualOn }
    }

    /// The lid controller finished a `pmset` run, which happens off the main actor and after ``evaluate()`` returned.
    private func lidApplied(active: Bool, enableFailed: Bool) {
        guard !isShutDown else { return }
        if active != lidActive { lidActive = active }
        if enableFailed {
            core.lidModeEnabled = false
            evaluate()
        }
    }
}
