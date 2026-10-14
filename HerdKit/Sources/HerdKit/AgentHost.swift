import Foundation

/// Where a local agent's terminal lives, as far as the process table and IDE lock files can tell.
public enum AgentHost: Sendable, Equatable {
    /// Under a herdr server: the pane is herdr's, not a window this app can script.
    case herdr
    /// Directly in iTerm2. `tty` is the bare device name, for example `ttys004`.
    case iTerm2(tty: String)
    /// Directly in Terminal.app.
    case terminalApp(tty: String)
    /// Under tmux. `paneTty` is the agent's tty, a pty slave owned by the tmux server, matched against
    /// `tmux list-panes` at click time. The outer terminal is found then too: the tmux server is a daemon,
    /// so the agent's own parent chain never reaches the terminal app.
    case tmux(paneTty: String)
    /// An IDE that registered itself in `~/.claude/ide`.
    case ide(pid: Int32, name: String)
    /// Any other `.app` ancestor.
    case app(bundleId: String, pid: Int32)
    case unknown
}

/// The subset of `~/.claude/ide/<port>.lock` this app reads. The file also holds an auth token, which is
/// deliberately not declared here, so decoding never materialises it.
struct IdeLock: Decodable {
    let pid: Int32
    let workspaceFolders: [String]
    let ideName: String?
}

/// Works out an ``AgentHost`` from the process table, without any subprocess.
public struct AgentHostResolver: Sendable {
    public typealias AppLookup = @Sendable (_ pid: Int32, _ appPath: String) -> (bundleId: String, pid: Int32)?

    static let appMarker = ".app/Contents/MacOS/"

    private let processes: any ProcessInspecting
    private let ideLockDirectory: URL
    private let appLookup: AppLookup

    /// - Parameter appLookup: Resolves the `.app` bundle at `appPath` (whose executable is process `pid`) to
    ///   a running application. Injected because `NSRunningApplication` is not available to HerdKit tests.
    public init(
        processes: any ProcessInspecting = DarwinProcessInspector(),
        ideLockDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide"),
        appLookup: @escaping AppLookup
    ) {
        self.processes = processes
        self.ideLockDirectory = ideLockDirectory
        self.appLookup = appLookup
    }

    /// - Parameters:
    ///   - pid: The agent process.
    ///   - tty: The agent's bare tty name, needed to name an iTerm2 or Terminal tab.
    ///   - cwd: Checked against IDE workspace folders. Empty skips the IDE check.
    ///   - detectMultiplexers: `false` when resolving a tmux client, whose own chain is the outer terminal.
    public func resolve(pid: Int32?, tty: String?, cwd: String, detectMultiplexers: Bool = true) -> AgentHost {
        // The IDE lock only matches by folder, so it must not outrank the chain: an agent in iTerm2 on a repo
        // an IDE also has open belongs to iTerm2. It wins when the IDE is an ancestor, else it is the fallback.
        let ide = cwd.isEmpty ? nil : ideHost(for: cwd)
        let idePid: Int32? = if case .ide(let p, _)? = ide { p } else { nil }
        guard let pid else { return ide ?? .unknown }
        var current = processes.parentPid(of: pid)
        var hops = 0
        while let p = current, p > 1, hops < 64 {
            if p == idePid, let ide { return ide }
            let name = processes.name(of: p) ?? ""
            if detectMultiplexers, name.hasPrefix("tmux") {
                return tty.map { .tmux(paneTty: $0) } ?? ide ?? .unknown
            }
            if name == "herdr" { return .herdr }
            if let path = processes.executablePath(of: p), let appPath = Self.outermostApp(in: path),
                let app = appLookup(p, appPath)
            {
                if app.pid == idePid, let ide { return ide }
                switch (app.bundleId, tty) {
                case ("com.googlecode.iterm2", let tty?): return .iTerm2(tty: tty)
                case ("com.apple.Terminal", let tty?): return .terminalApp(tty: tty)
                default: return .app(bundleId: app.bundleId, pid: app.pid)
                }
            }
            current = processes.parentPid(of: p)
            hops += 1
        }
        return ide ?? .unknown
    }

    /// The outermost `.app` bundle of an executable inside one. An Electron helper lives in a nested
    /// `Frameworks/X Helper.app`, and it is the outer bundle that is the running application.
    static func outermostApp(in path: String) -> String? {
        guard path.contains(appMarker), let end = path.range(of: ".app/") else { return nil }
        return String(path[..<path.index(end.lowerBound, offsetBy: 4)])
    }

    /// The IDE whose workspace folder contains `cwd`, longest folder winning, skipping dead IDEs.
    private func ideHost(for cwd: String) -> AgentHost? {
        let files = (try? FileManager.default.contentsOfDirectory(at: ideLockDirectory, includingPropertiesForKeys: nil)) ?? []
        var best: (length: Int, pid: Int32, name: String)?
        for file in files where file.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: file), let lock = try? JSONDecoder().decode(IdeLock.self, from: data),
                processes.isAlive(lock.pid)
            else { continue }
            for folder in lock.workspaceFolders {
                let root = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
                guard cwd == root || cwd.hasPrefix(root + "/"), root.count > (best?.length ?? -1) else { continue }
                best = (root.count, lock.pid, lock.ideName ?? "IDE")
            }
        }
        return best.map { .ide(pid: $0.pid, name: $0.name) }
    }
}

/// What a click on a local agent should do. Pure, so the decision table is testable.
public enum AgentJumpPlan: Sendable, Equatable {
    /// Select the iTerm2 or Terminal.app tab showing `tty`.
    case terminalTab(bundleId: String, tty: String)
    /// Select the tmux pane showing `paneTty`, then raise the outer terminal.
    case tmuxPane(paneTty: String)
    /// Bring the process's application forward.
    case activate(pid: Int32)
    case activateBundle(String)
    case cannotLocate

    /// - Parameter fallbackBundleId: The user's terminal override, used only when detection found nothing
    ///   (or only herdr, whose pane cannot be addressed without its socket).
    public static func plan(for host: AgentHost, fallbackBundleId: String?) -> AgentJumpPlan {
        switch host {
        case .iTerm2(let tty): return .terminalTab(bundleId: "com.googlecode.iterm2", tty: tty)
        case .terminalApp(let tty): return .terminalTab(bundleId: "com.apple.Terminal", tty: tty)
        case .tmux(let paneTty): return .tmuxPane(paneTty: paneTty)
        case .ide(let pid, _), .app(_, let pid): return .activate(pid: pid)
        case .herdr, .unknown:
            guard let id = fallbackBundleId, !id.isEmpty else { return .cannotLocate }
            return .activateBundle(id)
        }
    }
}
