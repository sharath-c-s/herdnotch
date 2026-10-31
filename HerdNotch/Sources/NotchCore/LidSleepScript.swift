import Foundation

/// Pure builders for the one-time admin scripts that let HerdNotch run `pmset disablesleep` without a prompt.
///
/// The script text is fixed. The only interpolated value is the account name, which must pass
/// ``isValidUsername(_:)`` first, so it can never carry shell or AppleScript metacharacters.
public enum LidSleepScript {
    public static let sudoersPath = "/etc/sudoers.d/herdnotch-lidsleep"

    /// Matches `^[A-Za-z_][A-Za-z0-9_.-]*$`, checked by hand because `$` in a regex also accepts a trailing newline.
    public static func isValidUsername(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else { return false }
        func lower(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x41 && s.value <= 0x5A)
        }
        func digit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }
        guard lower(first) || first == "_" else { return false }
        return scalars.dropFirst().allSatisfy { lower($0) || digit($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    public static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }

    /// Shell script that validates the rule with visudo before installing it. `nil` for an invalid username.
    public static func installShellScript(user: String) -> String? {
        guard isValidUsername(user) else { return nil }
        let rule = sudoersRule(user: user)
        return "T=$(/usr/bin/mktemp /tmp/herdnotch-lidsleep.XXXXXX) "
            + "&& /usr/bin/printf '%s\\n' '\(rule)' > \"$T\" "
            + "&& /usr/sbin/visudo -cf \"$T\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$T\" \(sudoersPath); "
            + "R=$?; /bin/rm -f \"$T\"; exit $R"
    }

    /// Turns `disablesleep` off before the rule goes, so no race can leave it on with no way to undo it.
    public static let uninstallShellScript = "/usr/bin/pmset disablesleep 0; /bin/rm -f \(sudoersPath)"

    /// Wraps a shell script as the AppleScript source `osascript -e` runs, escaping `\` then `"`.
    public static func appleScript(wrapping shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    public static func installAppleScript(user: String) -> String? {
        installShellScript(user: user).map(appleScript(wrapping:))
    }

    public static var uninstallAppleScript: String { appleScript(wrapping: uninstallShellScript) }

    /// Whether `pmset -g` output shows `SleepDisabled` set to 1. The key is absent when never set.
    public static func sleepDisabled(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }
}

/// Why an admin-prompted install or removal did or did not happen.
public enum LidInstallResult: Equatable, Sendable {
    case ok
    case invalidUsername
    /// The user dismissed the macOS admin prompt.
    case cancelled
    case failed

    public var message: String? {
        switch self {
        case .ok: nil
        case .invalidUsername: "This account name cannot be used in the rule."
        case .cancelled: "Cancelled."
        case .failed: "The change failed."
        }
    }
}

public extension LidSleepScript {
    /// `osascript` reports a dismissed admin prompt as error -128 ("User canceled.") on stderr.
    static func classifyAdminRun(status: Int32, stderr: String) -> LidInstallResult {
        if status == 0 { return .ok }
        return stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("user canceled") ? .cancelled : .failed
    }
}

/// Runs one subprocess (`path`, argv) and returns its exit status and stdout. Injected so tests spawn nothing.
public typealias LidCommandRunner = @Sendable (_ path: String, _ args: [String]) -> (status: Int32, output: String)

/// The `pmset disablesleep` state machine behind the lid-closed mode, with the process runner injected.
///
/// The persisted flag is set when this app turns `disablesleep` on and cleared only when it turns it off, so a
/// crash leaves it true: launch recovery reverts only a state this app set, never one set by the user.
///
/// `@unchecked Sendable`: the only state is `UserDefaults` (thread-safe) and an immutable `@Sendable` runner.
public final class LidSleepCore: @unchecked Sendable {
    public static let activeFlagKey = "herdnotch.lidModeActive"

    private let defaults: UserDefaults
    private let run: LidCommandRunner

    public init(defaults: UserDefaults, run: @escaping LidCommandRunner) {
        self.defaults = defaults
        self.run = run
    }

    public var isFlagActive: Bool { defaults.bool(forKey: Self.activeFlagKey) }

    /// `sudo -n` never prompts; `false` means no sudoers rule or the command failed.
    @discardableResult
    public func setDisableSleep(_ on: Bool) -> Bool {
        let result = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"])
        guard result.status == 0 else { return false }
        defaults.set(on, forKey: Self.activeFlagKey)
        return true
    }

    /// Call once at launch: no session of ours is live, so a set flag is a crash leftover. Does nothing without
    /// the flag; with it, reverts `SleepDisabled 1` and clears the flag whatever the outcome.
    public func recoverIfNeeded() {
        guard isFlagActive else { return }
        let output = run("/usr/bin/pmset", ["-g"]).output
        if LidSleepScript.sleepDisabled(pmsetOutput: output) { setDisableSleep(false) }
        defaults.set(false, forKey: Self.activeFlagKey)
    }

    public func shutdown() {
        if isFlagActive { setDisableSleep(false) }
    }

    /// For after the uninstall script, which already turned `disablesleep` off as root.
    public func clearFlag() { defaults.set(false, forKey: Self.activeFlagKey) }

    /// Moves lid mode toward `want` and returns whether it is now active, spawning only when `want` differs
    /// from `active`. A failed turn-off still reports inactive, so a removed sudoers rule cannot make every
    /// later call retry `sudo`. A failed turn-on reads `pmset -g` instead of trusting the exit status: a
    /// timeout can kill `sudo` after `pmset` already applied, and that state must be recorded to be undone.
    public func reconcile(want: Bool, active: Bool) -> (active: Bool, enableFailed: Bool) {
        guard want != active else { return (active, false) }
        if setDisableSleep(want) { return (want, false) }
        guard want else { return (false, false) }
        let applied = LidSleepScript.sleepDisabled(pmsetOutput: run("/usr/bin/pmset", ["-g"]).output)
        if applied { defaults.set(true, forKey: Self.activeFlagKey) }
        return (applied, !applied)
    }
}

/// Coalesces lid-mode requests onto one serial executor: only the latest wanted state is applied, one run at
/// a time, and each outcome goes to ``onResult``. Thread-safe; `async` and `sync` must run jobs on the same
/// serial queue. The executors are injected so tests step the runs by hand.
public final class LidSleepScheduler: @unchecked Sendable {
    public typealias Job = @Sendable () -> Void

    private let core: LidSleepCore
    private let async: (@escaping Job) -> Void
    private let sync: (Job) -> Void
    private let lock = NSLock()
    private var wanted = false
    private var active = false
    private var running = false
    private var removing = false
    private var isShutDown = false
    private var resultHandler: (@Sendable (_ active: Bool, _ enableFailed: Bool) -> Void)?

    public init(core: LidSleepCore, async: @escaping (@escaping Job) -> Void, sync: @escaping (Job) -> Void) {
        self.core = core
        self.async = async
        self.sync = sync
    }

    /// Called from the executor (or `endRemoval`'s caller) after a run: whether lid mode is now active, and
    /// whether a turn-on failed. Not called after ``shutdown()``.
    public var onResult: (@Sendable (_ active: Bool, _ enableFailed: Bool) -> Void)? {
        get { lock.withLock { resultHandler } }
        set { lock.withLock { resultHandler = newValue } }
    }

    public func reconcile(want: Bool) {
        lock.withLock { wanted = want }
        pump()
    }

    /// Blocks every turn-on until ``endRemoval(succeeded:)``; a turn-off still runs. Jobs already queued finish first.
    public func beginRemoval() {
        lock.withLock { removing = true }
    }

    /// After a successful removal the admin script has already turned `disablesleep` off, so state resets
    /// to inactive. After a cancel or failure, normal operation resumes toward the latest wanted state.
    public func endRemoval(succeeded: Bool) {
        let wasActive = lock.withLock {
            removing = false
            guard succeeded else { return false }
            wanted = false
            defer { active = false }
            return active
        }
        if succeeded { core.clearFlag() }
        if wasActive, !lock.withLock({ isShutDown }) { onResult?(false, false) }
        pump()
    }

    /// Call once at launch; queued ahead of any later request.
    public func recoverIfNeeded() {
        async { [core] in core.recoverIfNeeded() }
    }

    /// Blocks until queued runs finish and `disablesleep` is back off; later requests are dropped.
    public func shutdown() {
        lock.withLock { isShutDown = true }
        sync { [core] in core.shutdown() }
    }

    private func pump() {
        let job: (want: Bool, current: Bool)? = lock.withLock {
            guard !running, !isShutDown else { return nil }
            let target = removing ? false : wanted
            guard target != active else { return nil }
            running = true
            return (target, active)
        }
        guard let job else { return }
        async { [self] in
            if lock.withLock({ isShutDown }) {
                lock.withLock { running = false }
                return
            }
            finished(core.reconcile(want: job.want, active: job.current))
        }
    }

    private func finished(_ result: (active: Bool, enableFailed: Bool)) {
        let report = lock.withLock {
            running = false
            active = result.active
            // A failed turn-on must not retry: the caller drops lid mode, and `wanted` follows.
            if result.enableFailed { wanted = false }
            return !isShutDown
        }
        if report { onResult?(result.active, result.enableFailed) }
        pump()
    }
}
