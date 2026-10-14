import AppKit
import Foundation
import HerdKit

/// What a click on a local agent did.
public enum HerdJumpOutcome: Sendable, Equatable {
    /// A jump was attempted. A tab that could not be selected still activates its app.
    case jumped
    /// ``HerdPreferences/jumpToAgentEnabled`` is off.
    case disabled
    /// Detection found no host and no fallback terminal is configured.
    case cannotLocate
}

/// Focuses an agent's pane in herdr and raises the terminal that hosts it.
///
/// This is what turns the panel from a dashboard into a switcher, and it is the reason the app reads
/// sessions rather than just counting them.
///
/// The sequence is three herdr calls in order, all verified against a live server:
/// `workspace.focus {workspace_id}`, then `tab.focus {tab_id}`, then `agent.focus {target}` where
/// `target` is the pane id. Each narrows the selection inside the previous one, so the order matters:
/// focusing the pane first and the workspace second would leave the wrong workspace showing.
///
/// Raising the terminal is separate from focusing the pane, because herdr moves its own cursor but
/// cannot bring another application forward. Which application that is cannot be derived from the
/// herdr API: `agent.list` reports an opaque `terminal_id` such as `term_657068fc62f8c2`, which
/// identifies a herdr-side terminal record, not a macOS bundle. Hence the auto-detect list plus the
/// `herdTerminalBundleId` override.
///
/// Local agents (`HerdAgent.source == .local`) have no herdr pane. ``focus(agent:in:)`` instead detects the
/// host (see ``AgentHostDetector``) and, unless ``HerdPreferences/jumpToAgentEnabled`` is off, selects the
/// iTerm2 or Terminal.app tab by tty, the tmux pane, or just activates the IDE or terminal app. It never
/// activates "some" terminal for an agent it cannot place.
///
/// Thread-safety: main-actor isolated, but the three herdr calls are blocking and therefore run on
/// ``queue``. Activation hops back to the main actor because `NSRunningApplication.activate()` is
/// main-thread-only.
@MainActor
public final class HerdFocusService {
    /// Bundle identifiers checked, in order, when no terminal is configured.
    ///
    /// Ordered by specificity rather than popularity: a user running both iTerm2 and Terminal.app is
    /// far more likely to be running herdr in iTerm2, and Terminal.app is often open incidentally.
    /// This list is only a default; ``HerdPreferences/terminalBundleId`` overrides it.
    private static let knownTerminalBundleIds = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.apple.Terminal"
    ]

    /// Settings source, read at click time so a preference change needs no restart.
    private let preferences: HerdPreferences

    /// Serial queue owning the blocking herdr calls, separate from the poll queue so a click is not
    /// stuck behind an in-flight poll.
    private let queue = DispatchQueue(label: "com.boringherd.focus", qos: .userInitiated)

    /// Reports the outcome of every cross-session terminal raise attempt, keyed by session name.
    ///
    /// `nil` by default, meaning nobody is listening. Exists so a future caller (the panel UI) can
    /// surface "nothing is attached to this session" instead of the click silently doing nothing; this
    /// type does not wire it to any UI itself. Always invoked on the main actor, since UI code is the
    /// only plausible consumer and everything else in this class already hops there for the same
    /// reason.
    var onFocusOutcome: (@Sendable (String, HerdTerminalRaiseOutcome) -> Void)?

    /// Reports what each click on a local agent did, on the main actor. The notch uses it to beep on
    /// ``HerdJumpOutcome/cannotLocate``.
    public var onJumpOutcome: ((HerdAgent, HerdJumpOutcome) -> Void)?

    /// Creates the service.
    ///
    /// - Parameter preferences: Provides the terminal bundle identifier override.
    public init(preferences: HerdPreferences) {
        self.preferences = preferences
    }

    /// Focuses one agent and raises its terminal.
    ///
    /// Returns immediately; the work happens on ``queue``. Errors are logged to standard error rather
    /// than surfaced in the UI: the only actionable failures are "the session just stopped" and "that
    /// pane just closed", and both are already visible in the next poll, one second later.
    ///
    /// - Parameters:
    ///   - agent: The agent to focus. Its `workspaceId`, `tabId` and `paneId` drive the three calls.
    ///   - session: The owning session, which supplies the socket path. A stopped session is ignored,
    ///     since there is nothing listening to focus.
    public func focus(agent: HerdAgent, in session: HerdSession) {
        if agent.source == .local {
            jump(to: agent)
            return
        }
        run(
            steps: [
                ("workspace.focus", ["workspace_id": .string(agent.workspaceId)]),
                ("tab.focus", ["tab_id": .string(agent.tabId)]),
                ("agent.focus", ["target": .string(agent.paneId)])
            ],
            describing: agent.paneId,
            in: session
        )
    }

    /// Focuses a whole workspace and raises its terminal.
    ///
    /// The first step of ``focus(agent:in:)`` on its own. Whichever tab and pane the workspace was last
    /// on stays selected, which is the right answer: the user asked for the workspace, not for a
    /// particular pane inside it, so overriding herdr's own memory of where they were would be a
    /// second, unasked-for decision.
    ///
    /// - Parameters:
    ///   - workspace: The workspace to focus.
    ///   - session: The owning session, which supplies the socket path.
    public func focus(workspace: HerdWorkspace, in session: HerdSession) {
        run(
            steps: [("workspace.focus", ["workspace_id": .string(workspace.workspaceId)])],
            describing: workspace.workspaceId,
            in: session
        )
    }

    /// Focuses a session and raises its terminal.
    ///
    /// herdr has no `session.focus`, because a session is a whole server rather than a thing inside
    /// one. The nearest true equivalent is to focus whichever of its workspaces herdr already reports
    /// as focused, which leaves the session exactly as the user left it and merely brings it forward.
    /// The first workspace is the fallback for a session herdr has not marked, and a session with no
    /// workspaces at all is a running server with nothing in it, where only the terminal raise is
    /// meaningful.
    ///
    /// - Parameter session: The session to focus.
    public func focus(session: HerdSession) {
        let target = session.workspaces.first(where: \.focused) ?? session.workspaces.first
        guard let target else {
            guard session.running, !session.isRemote,
                  let bundleId = resolvedTerminalBundleId() else { return }
            Self.activate(bundleId: bundleId)
            return
        }
        focus(workspace: target, in: session)
    }

    /// Sends an ordered list of herdr calls, then raises the terminal if every one of them succeeded.
    ///
    /// The order is never reordered or parallelised: each call narrows the selection inside the
    /// previous one, so focusing the pane before its workspace would leave the wrong workspace showing.
    /// A failure stops the sequence rather than pressing on, because the later calls address things
    /// inside the thing that just failed.
    ///
    /// Raising the terminal is now two-tiered. ``HerdTerminalWindowLocator`` is tried first, since it
    /// can bring forward the exact window attached to this session rather than just the application;
    /// only when it does not manage that (unsupported terminal, nothing attached, or AppleScript itself
    /// unavailable) does this fall back to the old behaviour of activating the application by bundle
    /// identifier, which is at least never wrong about *which app*, only sometimes wrong about *which
    /// window*. Both the locator work and the fallback activation run off the main actor: the locator
    /// because AppleScript can block for up to 2 seconds per attempt and an Automation permission
    /// prompt can block far longer than that, and the fallback only hops to the main actor for the
    /// instant that `NSRunningApplication.activate()` requires.
    ///
    /// - Parameters:
    ///   - steps: Method name and parameters, in the order they must be sent.
    ///   - subject: What is being focused, used only in the failure log line.
    ///   - session: The owning session. A stopped one is ignored, since nothing is listening.
    private func run(
        steps: [(String, [String: HerdrParam])],
        describing subject: String,
        in session: HerdSession
    ) {
        // The synthetic local session has no socket: there is no herdr to call.
        guard session.running, !session.socketPath.isEmpty else { return }
        let socketPath = session.socketPath
        let sessionName = session.name
        // No terminal is raised for a session reached through a forwarded socket. The herdr calls are still
        // worth sending, because they move the selection on the remote machine and it will be waiting when
        // the user gets there, but the window hosting that session is on another host: every local terminal
        // this app could raise is showing something else, so raising one would be actively misleading in
        // the same way the pre-attachment-probe build was. The panel marks these sessions `remote`, which is
        // where the user finds out why nothing came forward.
        let bundleId = session.isRemote ? nil : resolvedTerminalBundleId()
        let reportOutcome = onFocusOutcome

        queue.async {
            let client = HerdrClient(socketPath: socketPath)
            for (method, params) in steps {
                do {
                    _ = try client.call(method, params: params)
                } catch {
                    FileHandle.standardError.write(
                        Data("herd: \(method) for \(subject) failed: \(error)\n".utf8)
                    )
                    return
                }
            }
            guard let bundleId else { return }

            let locator = HerdTerminalWindowLocator()
            var raised = false
            do {
                let outcome = try locator.raise(sessionName: sessionName, socketPath: socketPath, bundleId: bundleId)
                FileHandle.standardError.write(
                    Data("herd: cross-session raise for \(sessionName): \(outcome)\n".utf8)
                )
                if let reportOutcome {
                    Task { @MainActor in reportOutcome(sessionName, outcome) }
                }
                if case .raised = outcome {
                    raised = true
                }
            } catch {
                FileHandle.standardError.write(
                    Data("herd: cross-session raise for \(sessionName) failed: \(error)\n".utf8)
                )
            }

            guard !raised else { return }
            Task { @MainActor in Self.activate(bundleId: bundleId) }
        }
    }

    /// Brings a local agent's host forward. Detection and the tmux and AppleScript steps run on ``queue``;
    /// only the final activation hops back to the main actor.
    private func jump(to agent: HerdAgent) {
        guard preferences.jumpToAgentEnabled else {
            onJumpOutcome?(agent, .disabled)
            return
        }
        let fallback = preferences.terminalBundleId
        queue.async { [weak self] in
            let host = AgentHostDetector().detect(agent)
            let plan = AgentJumpPlan.plan(for: host, fallbackBundleId: fallback)
            let (outcome, activation) = Self.execute(plan)
            Task { @MainActor in
                switch activation {
                case .pid(let pid): NSRunningApplication(processIdentifier: pid)?.activate()
                case .bundle(let id): Self.activate(bundleId: id)
                case nil: break
                }
                self?.onJumpOutcome?(agent, outcome)
            }
        }
    }

    private enum Activation: Sendable {
        case pid(Int32)
        case bundle(String)
    }

    /// Runs the parts of a plan that can run off the main actor and says what is left to activate.
    private nonisolated static func execute(_ plan: AgentJumpPlan) -> (HerdJumpOutcome, Activation?) {
        switch plan {
        case .cannotLocate:
            return (.cannotLocate, nil)
        case .activate(let pid):
            return (.jumped, .pid(pid))
        case .activateBundle(let id):
            return (.jumped, .bundle(id))
        case .terminalTab(let bundleId, let tty):
            let outcome = HerdTerminalWindowLocator().raise(tty: tty, bundleId: bundleId)
            if case .raised = outcome { return (.jumped, nil) }
            FileHandle.standardError.write(Data("herd: tty raise \(tty): \(outcome)\n".utf8))
            return (.jumped, .bundle(bundleId))
        case .tmuxPane(let paneTty):
            return jumpTmux(paneTty: paneTty)
        }
    }

    /// Selects the pane in tmux, then raises the terminal the attached client runs in.
    private nonisolated static func jumpTmux(paneTty: String) -> (HerdJumpOutcome, Activation?) {
        guard let tmux = tmuxPath(),
              let panes = run(tmux, TmuxJump.listPanesArgs),
              let pane = TmuxJump.findPane(tty: paneTty, in: panes)
        else { return (.cannotLocate, nil) }
        let client = run(tmux, TmuxJump.listClientsArgs).flatMap { TmuxJump.pickClient(for: pane.session, in: $0) }
        for command in TmuxJump.selectCommands(pane: pane, client: client) { _ = run(tmux, command) }
        guard let client else { return (.jumped, nil) }
        // The client's own chain ends at the outer terminal (the server's does not: it is a daemon).
        let outer = AgentHostDetector().resolver.resolve(
            pid: client.pid, tty: client.tty, cwd: "", detectMultiplexers: false)
        switch AgentJumpPlan.plan(for: outer, fallbackBundleId: nil) {
        case .terminalTab(let bundleId, let tty):
            if case .raised = HerdTerminalWindowLocator().raise(tty: tty, bundleId: bundleId) { return (.jumped, nil) }
            return (.jumped, .bundle(bundleId))
        case .activate(let pid): return (.jumped, .pid(pid))
        default: return (.jumped, nil)
        }
    }

    private nonisolated static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `executable` with an argv array and returns stdout, or `nil` on a non-zero exit, a launch
    /// failure or a 2 second timeout. Never a shell.
    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard let output = try? BlockingProcess.run(executable, arguments, timeout: 2), output.succeeded else { return nil }
        return output.stdout
    }

    /// The terminal to raise: the configured override, else the first known terminal that is running.
    ///
    /// - Returns: A bundle identifier, or `nil` when nothing recognisable is running, in which case
    ///   the pane is still focused inside herdr and only the app raise is skipped.
    private func resolvedTerminalBundleId() -> String? {
        if let configured = preferences.terminalBundleId { return configured }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.knownTerminalBundleIds.first(where: running.contains)
    }

    /// Brings the given application forward.
    ///
    /// Iterates every instance rather than taking the first, because a terminal can legitimately have
    /// several processes and only one of them owns the herdr window; activating all of them raises the
    /// right one and costs nothing.
    ///
    /// - Parameter bundleId: Bundle identifier of the application to raise.
    private static func activate(bundleId: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            app.activate()
        }
    }
}
