import Foundation
import HerdKit
import NotchCore

/// Runs `pmset disablesleep` through a passwordless sudoers rule installed once with an admin prompt.
///
/// Every subprocess takes an argv array, never a shell string. The state machine lives in
/// ``LidSleepScheduler`` and ``LidSleepCore`` (tested in NotchCore); this type adds the serial queue, the
/// sudoers install/removal and the SwiftUI-facing `isSetUp`.
///
/// `sudo -n pmset` runs on a serial queue with a 2 s kill timeout, never on the main actor. Requests
/// coalesce: only the latest wanted state is applied, one run at a time, and the outcome is published
/// through ``onResult`` on the main actor. ``shutdown()`` is the one synchronous path (the process is exiting).
@MainActor
final class LidSleepController: ObservableObject {
    static let activeFlagKey = LidSleepCore.activeFlagKey

    /// Shared with the settings window, which `main.swift` builds without access to the window controller.
    static let shared = LidSleepController()

    @Published private(set) var isSetUp: Bool
    /// Called on the main actor when a run finishes: whether lid mode is now active, and whether a turn-on failed.
    var onResult: ((_ active: Bool, _ enableFailed: Bool) -> Void)?

    private let core: LidSleepCore
    private let scheduler: LidSleepScheduler
    private let queue: DispatchQueue

    init(
        defaults: UserDefaults = .standard,
        run: @escaping LidCommandRunner = { path, args in
            let output = try? BlockingProcess.run(path, args, timeout: 2)
            return (output?.status ?? -1, output?.stdout ?? "")
        }
    ) {
        let core = LidSleepCore(defaults: defaults, run: run)
        let queue = DispatchQueue(label: "com.boringherd.lidsleep", qos: .userInitiated)
        self.core = core
        self.queue = queue
        scheduler = LidSleepScheduler(
            core: core, async: { queue.async(execute: $0) }, sync: { queue.sync(execute: $0) })
        isSetUp = FileManager.default.fileExists(atPath: LidSleepScript.sudoersPath)
        scheduler.onResult = { [weak self] active, enableFailed in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onResult?(active, enableFailed) } }
        }
    }

    var isLidModeActive: Bool { core.isFlagActive }

    func refreshSetUp() {
        isSetUp = FileManager.default.fileExists(atPath: LidSleepScript.sudoersPath)
    }

    /// Shows the macOS admin prompt.
    func install() async -> LidInstallResult {
        guard let script = LidSleepScript.installAppleScript(user: NSUserName()) else { return .invalidUsername }
        return await runAdmin(script)
    }

    /// The admin script turns `disablesleep` off before removing the rule. Turn-ons are blocked meanwhile.
    func uninstall() async -> LidInstallResult {
        scheduler.beginRemoval()
        // Let a turn-on already on the queue finish, so it cannot land after the script's turn-off.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let result = await runAdmin(LidSleepScript.uninstallAppleScript)
        scheduler.endRemoval(succeeded: result == .ok)
        return result
    }

    private func runAdmin(_ appleScript: String) async -> LidInstallResult {
        let result = await Task.detached {
            // No timeout: the admin prompt waits as long as the user does.
            let run = try? BlockingProcess.run("/usr/bin/osascript", ["-e", appleScript])
            return LidSleepScript.classifyAdminRun(status: run?.status ?? -1, stderr: run?.stderr ?? "")
        }.value
        refreshSetUp()
        return result
    }

    /// Asks for lid mode to be `want`. Returns at once; the outcome arrives through ``onResult``.
    func reconcile(want: Bool) { scheduler.reconcile(want: want) }

    /// Call once at launch: undoes a `disablesleep 1` left behind by a crash. Runs ahead of any later request.
    func recoverIfNeeded() { scheduler.recoverIfNeeded() }

    /// Blocks for at most the run in flight plus one more (2 s timeout each); later requests are dropped.
    func shutdown() { scheduler.shutdown() }
}
