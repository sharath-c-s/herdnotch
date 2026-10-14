import Foundation
import Testing

@testable import NotchCore

@Suite struct KeepAwakeConditionsTests {
    @Test func nothingEnabledNothingHeld() {
        let inputs = KeepAwakeInputs(anyAgentWorking: true, runningBundleIds: ["a"], onCharger: true, externalDisplay: true)
        #expect(!KeepAwakeConditions().shouldHold(inputs))
    }

    @Test func manualAlwaysHolds() {
        #expect(KeepAwakeConditions().shouldHold(KeepAwakeInputs(manualOn: true)))
    }

    @Test func eachConditionHoldsOnlyWhenEnabledAndTrue() {
        #expect(KeepAwakeConditions(anyAgentWorking: true).shouldHold(KeepAwakeInputs(anyAgentWorking: true)))
        #expect(!KeepAwakeConditions(anyAgentWorking: true).shouldHold(KeepAwakeInputs()))
        #expect(KeepAwakeConditions(onCharger: true).shouldHold(KeepAwakeInputs(onCharger: true)))
        #expect(KeepAwakeConditions(externalDisplay: true).shouldHold(KeepAwakeInputs(externalDisplay: true)))
        let app = KeepAwakeConditions(appRunningBundleIds: ["com.x"])
        #expect(app.shouldHold(KeepAwakeInputs(runningBundleIds: ["com.x", "com.y"])))
        #expect(!app.shouldHold(KeepAwakeInputs(runningBundleIds: ["com.y"])))
    }

    @Test func emptyAppListNeverMatches() {
        #expect(!KeepAwakeConditions().shouldHold(KeepAwakeInputs(runningBundleIds: ["com.x"])))
    }

    @Test func lidModeCutoff() {
        #expect(!KeepAwakeConditions.lidModeAllowed(batteryPercent: 20, onCharger: false))
        #expect(KeepAwakeConditions.lidModeAllowed(batteryPercent: 21, onCharger: false))
        #expect(KeepAwakeConditions.lidModeAllowed(batteryPercent: 3, onCharger: true))
        #expect(KeepAwakeConditions.lidModeAllowed(batteryPercent: 40, onCharger: false, cutoff: 30))
        #expect(!KeepAwakeConditions.lidModeAllowed(batteryPercent: 30, onCharger: false, cutoff: 30))
    }
}

@Suite struct SustainedGateTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func firesOnceAfterDuration() {
        var gate = SustainedGate(threshold: 90, duration: 120, hysteresis: 5)
        let r1 = gate.update(value: 95, now: t0)
        #expect(!r1)
        let r2 = gate.update(value: 95, now: t0.addingTimeInterval(119))
        #expect(!r2)
        let r3 = gate.update(value: 95, now: t0.addingTimeInterval(120))
        #expect(r3)
        let r4 = gate.update(value: 95, now: t0.addingTimeInterval(500))
        #expect(!r4)
    }

    @Test func dipResetsTimer() {
        var gate = SustainedGate(threshold: 90, duration: 120)
        _ = gate.update(value: 95, now: t0)
        _ = gate.update(value: 50, now: t0.addingTimeInterval(100))
        let r5 = gate.update(value: 95, now: t0.addingTimeInterval(110))
        #expect(!r5)
        let r6 = gate.update(value: 95, now: t0.addingTimeInterval(229))
        #expect(!r6)
        let r7 = gate.update(value: 95, now: t0.addingTimeInterval(230))
        #expect(r7)
    }

    @Test func rearmsOnlyBelowHysteresisBand() {
        var gate = SustainedGate(threshold: 90, duration: 10, hysteresis: 5)
        _ = gate.update(value: 95, now: t0)
        let r8 = gate.update(value: 95, now: t0.addingTimeInterval(10))
        #expect(r8)
        _ = gate.update(value: 88, now: t0.addingTimeInterval(20))  // inside band, still disarmed
        _ = gate.update(value: 95, now: t0.addingTimeInterval(30))
        let r9 = gate.update(value: 95, now: t0.addingTimeInterval(60))
        #expect(!r9)
        _ = gate.update(value: 80, now: t0.addingTimeInterval(70))  // below 85, rearms
        _ = gate.update(value: 95, now: t0.addingTimeInterval(80))
        let r10 = gate.update(value: 95, now: t0.addingTimeInterval(90))
        #expect(r10)
    }

    @Test func equalToThresholdIsNotAbove() {
        var gate = SustainedGate(threshold: 90, duration: 0)
        let r11 = gate.update(value: 90, now: t0)
        #expect(!r11)
        let r12 = gate.update(value: 90.1, now: t0)
        #expect(r12)
    }
}

@Suite struct PowerFormatTests {
    @Test func health() {
        #expect(PowerFormat.healthPercent(rawMaxCapacity: 4500, designCapacity: 5000) == 90)
        #expect(PowerFormat.healthPercent(rawMaxCapacity: nil, designCapacity: 5000) == nil)
        #expect(PowerFormat.healthPercent(rawMaxCapacity: 4500, designCapacity: 0) == nil)
    }

    @Test func watts() {
        #expect(PowerFormat.watts(amperageMA: -1000, voltageMV: 12000) == 12)
        #expect(PowerFormat.wattsText(12.34) == "12.3 W")
    }

    @Test func timeRemaining() {
        #expect(PowerFormat.timeRemaining(minutes: 192) == "3h 12m")
        #expect(PowerFormat.timeRemaining(minutes: 45) == "45m")
        #expect(PowerFormat.timeRemaining(minutes: 0) == "0m")
        #expect(PowerFormat.timeRemaining(minutes: -1) == "--")
        #expect(PowerFormat.timeRemaining(minutes: nil) == "--")
    }

    @Test func cycles() {
        #expect(PowerFormat.cycleText(312) == "312")
        #expect(PowerFormat.cycleText(nil) == "--")
    }
}

@Suite struct LidSleepScriptTests {
    @Test func validUsernames() {
        for name in ["sharath", "_svc", "a.b-c_1", "bob", "Bob", "Sharath_C"] { #expect(LidSleepScript.isValidUsername(name), "\(name)") }
    }

    @Test func rejectedUsernames() {
        let bad = ["", "bob; rm -rf /", "bo\"b", "bo'b", "Bob Smith", "bob smith", "1bob", "-bob", "bob\n",
                   "bob$(id)", "bob`id`", "bob\\", "bób"]
        for name in bad {
            #expect(!LidSleepScript.isValidUsername(name), "\(name)")
            #expect(LidSleepScript.installShellScript(user: name) == nil)
            #expect(LidSleepScript.installAppleScript(user: name) == nil)
        }
    }

    @Test func ruleIsExact() {
        #expect(LidSleepScript.sudoersRule(user: "sharath")
            == "sharath ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0")
    }

    @Test func installScriptShape() throws {
        let script = try #require(LidSleepScript.installShellScript(user: "sharath"))
        #expect(script.contains("/usr/bin/mktemp"))
        #expect(script.contains("/usr/sbin/visudo -cf \"$T\""))
        #expect(script.contains("/usr/bin/install -m 0440 -o root -g wheel \"$T\" /etc/sudoers.d/herdnotch-lidsleep"))
        #expect(script.contains("'sharath ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0'"))
        #expect(script.contains("/bin/rm -f \"$T\""))
    }

    @Test func appleScriptEscaping() throws {
        let wrapped = LidSleepScript.appleScript(wrapping: #"a"b\c"#)
        #expect(wrapped == #"do shell script "a\"b\\c" with administrator privileges"#)
        let full = try #require(LidSleepScript.installAppleScript(user: "sharath"))
        #expect(full.hasPrefix("do shell script \""))
        #expect(full.hasSuffix("\" with administrator privileges"))
        // Every inner double quote is escaped.
        let inner = full.dropFirst("do shell script \"".count).dropLast("\" with administrator privileges".count)
        var prev: Character = " "
        for ch in inner { if ch == "\"" { #expect(prev == "\\") }; prev = ch }
    }

    @Test func uninstallTurnsSleepBackOnThenTouchesOnlyOurPath() {
        let shell = "/usr/bin/pmset disablesleep 0; /bin/rm -f /etc/sudoers.d/herdnotch-lidsleep"
        #expect(LidSleepScript.uninstallShellScript == shell)
        #expect(LidSleepScript.uninstallAppleScript == "do shell script \"\(shell)\" with administrator privileges")
    }

    @Test func parsesPmset() {
        #expect(LidSleepScript.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\n sleep 1\n"))
        #expect(!LidSleepScript.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled 0\n"))
        #expect(!LidSleepScript.sleepDisabled(pmsetOutput: "System-wide power settings:\n sleep 1\n"))
    }
}

@Suite struct LidSleepCoreTests {
    private final class Spy: @unchecked Sendable {
        var calls: [[String]] = []
        var pmsetOutput = ""
        var sudoStatus: Int32 = 0
        func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
            calls.append([path] + args)
            if path == "/usr/bin/pmset" { return (0, pmsetOutput) }
            return (sudoStatus, "")
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "lidcore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func recoveryTurnsSleepBackOnWhenCrashLeftTheFlagTrue() {
        let spy = Spy()
        spy.pmsetOutput = "System-wide power settings:\n SleepDisabled\t\t1\n"
        let defaults = makeDefaults()
        defaults.set(true, forKey: LidSleepCore.activeFlagKey)
        let core = LidSleepCore(defaults: defaults, run: spy.run)

        core.recoverIfNeeded()

        #expect(spy.calls.contains(["/usr/bin/sudo", "-n", "/usr/bin/pmset", "disablesleep", "0"]))
        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
    }

    @Test func recoveryLeavesUserSetDisableSleepAloneWhenFlagIsFalse() {
        let spy = Spy()
        spy.pmsetOutput = " SleepDisabled 1\n"
        let defaults = makeDefaults()
        let core = LidSleepCore(defaults: defaults, run: spy.run)

        core.recoverIfNeeded()

        #expect(spy.calls.isEmpty)
        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
    }

    @Test func recoveryClearsTheFlagWithoutSudoWhenSleepIsNotDisabled() {
        let spy = Spy()
        spy.pmsetOutput = " SleepDisabled 0\n"
        let defaults = makeDefaults()
        defaults.set(true, forKey: LidSleepCore.activeFlagKey)
        let core = LidSleepCore(defaults: defaults, run: spy.run)

        core.recoverIfNeeded()

        #expect(!spy.calls.contains { $0.first == "/usr/bin/sudo" })
        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
    }

    @Test func afterUninstallRepeatedReconcilesSpawnNothing() {
        let spy = Spy()
        spy.sudoStatus = 1
        let core = LidSleepCore(defaults: makeDefaults(), run: spy.run)

        var state = core.reconcile(want: false, active: true)
        #expect(!state.active)
        #expect(spy.calls.count == 1)
        state = core.reconcile(want: false, active: state.active)
        state = core.reconcile(want: false, active: state.active)
        #expect(spy.calls.count == 1)
    }

    @Test func failedEnableReportsInactiveAndFailure() {
        let spy = Spy()
        spy.sudoStatus = 1
        let core = LidSleepCore(defaults: makeDefaults(), run: spy.run)

        let result = core.reconcile(want: true, active: false)

        #expect(!result.active)
        #expect(result.enableFailed)
    }

    @Test func failedEnableThatPmsetShowsAppliedIsRecordedAsActive() {
        let spy = Spy()
        spy.sudoStatus = -1   // sudo killed on timeout after pmset ran
        spy.pmsetOutput = " SleepDisabled\t\t1\n"
        let defaults = makeDefaults()
        let core = LidSleepCore(defaults: defaults, run: spy.run)

        let result = core.reconcile(want: true, active: false)

        #expect(result.active)
        #expect(!result.enableFailed)
        #expect(defaults.bool(forKey: LidSleepCore.activeFlagKey))
    }

    @Test func adminRunClassification() {
        #expect(LidSleepScript.classifyAdminRun(status: 0, stderr: "") == .ok)
        #expect(LidSleepScript.classifyAdminRun(status: 1, stderr: "execution error: User canceled. (-128)") == .cancelled)
        #expect(LidSleepScript.classifyAdminRun(status: 1, stderr: "syntax error") == .failed)
    }
}

@Suite struct LidSleepSchedulerTests {
    private final class Spy: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var sudoStatus: Int32 = 0
        var pmsetOutput = ""
        func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
            lock.withLock { calls.append([path] + args) }
            return path == "/usr/bin/pmset" ? (0, pmsetOutput) : (sudoStatus, "")
        }
        var turnOns: Int { calls.filter { $0.last == "1" && $0.contains("disablesleep") }.count }
        var lastDisableSleep: String? { calls.last { $0.contains("disablesleep") }?.last }
    }

    /// Queues jobs until `step()` so a test controls what runs while another request arrives.
    private final class Manual: @unchecked Sendable {
        var jobs: [LidSleepScheduler.Job] = []
        func async(_ job: @escaping LidSleepScheduler.Job) { jobs.append(job) }
        func sync(_ job: LidSleepScheduler.Job) {
            drain()
            job()
        }
        func step() { if !jobs.isEmpty { jobs.removeFirst()() } }
        func drain() { while !jobs.isEmpty { step() } }
    }

    private final class Results: @unchecked Sendable {
        var all: [[Bool]] = []
    }

    private func make(_ spy: Spy) -> (LidSleepScheduler, Manual, Results, UserDefaults) {
        let suite = "lidsched-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manual = Manual()
        let results = Results()
        let scheduler = LidSleepScheduler(
            core: LidSleepCore(defaults: defaults, run: spy.run), async: manual.async, sync: manual.sync)
        scheduler.onResult = { results.all.append([$0, $1]) }
        return (scheduler, manual, results, defaults)
    }

    @Test func onOffOnWhileARunIsInFlightConvergesToOn() {
        let spy = Spy()
        let (scheduler, manual, results, _) = make(spy)

        scheduler.reconcile(want: true)
        scheduler.reconcile(want: false)
        scheduler.reconcile(want: true)
        manual.drain()

        #expect(spy.turnOns == 1)
        #expect(spy.lastDisableSleep == "1")
        #expect(results.all == [[true, false]])
    }

    @Test func aFailedTurnOnResetsWantedAndReportsInactive() {
        let spy = Spy()
        spy.sudoStatus = 1
        let (scheduler, manual, results, _) = make(spy)

        scheduler.reconcile(want: true)
        manual.drain()

        // `wanted` was reset, so nothing retries `sudo` on its own.
        #expect(results.all == [[false, true]])
        #expect(spy.calls.filter { $0.first == "/usr/bin/sudo" }.count == 1)
    }

    @Test func uninstallRacingATurnOnNeverRecordsDisableSleepOne() {
        let spy = Spy()
        let (scheduler, manual, _, _) = make(spy)

        scheduler.beginRemoval()
        scheduler.reconcile(want: true)
        manual.drain()
        #expect(spy.turnOns == 0)

        scheduler.endRemoval(succeeded: true)
        manual.drain()
        #expect(spy.turnOns == 0)
    }

    @Test func aSuccessfulUninstallClearsTheFlagAndReportsInactive() {
        let spy = Spy()
        let (scheduler, manual, results, defaults) = make(spy)
        scheduler.reconcile(want: true)
        manual.drain()
        #expect(defaults.bool(forKey: LidSleepCore.activeFlagKey))

        scheduler.beginRemoval()
        scheduler.endRemoval(succeeded: true)
        manual.drain()

        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
        #expect(results.all.last == [false, false])
        #expect(spy.turnOns == 1)
    }

    @Test func aCancelledUninstallResumesTheWantedState() {
        let spy = Spy()
        let (scheduler, manual, _, _) = make(spy)

        scheduler.beginRemoval()
        scheduler.reconcile(want: true)
        manual.drain()
        scheduler.endRemoval(succeeded: false)
        manual.drain()

        #expect(spy.turnOns == 1)
    }

    @Test func shutdownAfterAPendingRunTurnsOff() {
        let spy = Spy()
        let (scheduler, manual, results, defaults) = make(spy)
        scheduler.reconcile(want: true)
        manual.drain()
        scheduler.reconcile(want: false)   // queued, not yet run

        scheduler.shutdown()

        #expect(spy.lastDisableSleep == "0")
        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
        #expect(results.all == [[true, false]])
    }

    @Test func shutdownDropsAQueuedTurnOn() {
        let spy = Spy()
        let (scheduler, manual, _, defaults) = make(spy)
        scheduler.reconcile(want: true)   // queued, not yet run

        scheduler.shutdown()
        scheduler.reconcile(want: true)
        manual.drain()

        #expect(spy.turnOns == 0)
        #expect(!defaults.bool(forKey: LidSleepCore.activeFlagKey))
    }
}
