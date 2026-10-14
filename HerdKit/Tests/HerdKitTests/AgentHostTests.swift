import Foundation
import HerdKit
import Testing

private struct HostProcs: ProcessInspecting {
    struct P {
        var name = "x"
        var ppid: Int32 = 1
        var path: String? = nil
    }
    var procs: [Int32: P]
    func allPids() -> [Int32] { Array(procs.keys) }
    func isAlive(_ pid: Int32) -> Bool { procs[pid] != nil }
    func startTime(of pid: Int32) -> Int64? { procs[pid] != nil ? 1 : nil }
    func name(of pid: Int32) -> String? { procs[pid]?.name }
    func argv(of pid: Int32) -> [String]? { nil }
    func parentPid(of pid: Int32) -> Int32? { procs[pid]?.ppid }
    func cwd(of pid: Int32) -> String? { nil }
    func tty(of pid: Int32) -> String? { nil }
    func openRolloutPath(of pid: Int32) -> String? { nil }
    func executablePath(of pid: Int32) -> String? { procs[pid]?.path }
}

struct AgentHostTests {
    private let apps: AgentHostResolver.AppLookup = { pid, path in
        switch path {
        case "/Applications/iTerm.app": return ("com.googlecode.iterm2", pid)
        case "/System/Applications/Utilities/Terminal.app": return ("com.apple.Terminal", pid)
        case "/Applications/IntelliJ IDEA.app": return ("com.jetbrains.intellij", pid)
        default: return nil
        }
    }

    private func emptyDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolver(_ procs: [Int32: HostProcs.P], ide: URL) -> AgentHostResolver {
        AgentHostResolver(processes: HostProcs(procs: procs), ideLockDirectory: ide, appLookup: apps)
    }

    @Test func iTermAndTerminalAncestorsYieldTheAgentTty() throws {
        let dir = try emptyDir()
        let iterm = resolver([
            10: .init(name: "claude", ppid: 9), 9: .init(name: "zsh", ppid: 8),
            8: .init(name: "iTerm2", ppid: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ], ide: dir)
        #expect(iterm.resolve(pid: 10, tty: "ttys004", cwd: "/p") == .iTerm2(tty: "ttys004"))
        let term = resolver([
            10: .init(ppid: 8),
            8: .init(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ], ide: dir)
        #expect(term.resolve(pid: 10, tty: "ttys009", cwd: "/p") == .terminalApp(tty: "ttys009"))
    }

    @Test func tmuxAndHerdrWinOverAnOuterApp() throws {
        let dir = try emptyDir()
        let tmux = resolver([10: .init(ppid: 9), 9: .init(name: "zsh", ppid: 7), 7: .init(name: "tmux: server")], ide: dir)
        #expect(tmux.resolve(pid: 10, tty: "ttys020", cwd: "/p") == .tmux(paneTty: "ttys020"))
        // A tmux client's own chain is the outer terminal, so it must not stop at a tmux ancestor.
        #expect(tmux.resolve(pid: 10, tty: "ttys020", cwd: "/p", detectMultiplexers: false) == .unknown)
        let herdr = resolver([10: .init(ppid: 7), 7: .init(name: "herdr")], ide: dir)
        #expect(herdr.resolve(pid: 10, tty: "ttys020", cwd: "/p") == .herdr)
    }

    @Test func otherAppAncestorAndUnknown() throws {
        let dir = try emptyDir()
        let idea = resolver([
            10: .init(ppid: 8),
            8: .init(name: "idea", path: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
        ], ide: dir)
        #expect(idea.resolve(pid: 10, tty: "ttys001", cwd: "/p") == .app(bundleId: "com.jetbrains.intellij", pid: 8))
        #expect(resolver([10: .init(ppid: 1)], ide: dir).resolve(pid: 10, tty: nil, cwd: "/p") == .unknown)
        #expect(resolver([:], ide: dir).resolve(pid: nil, tty: nil, cwd: "/p") == .unknown)
    }

    @Test func ideLockIsTheFallbackByWorkspaceFolderAndIgnoresTheToken() throws {
        let dir = try emptyDir()
        let lock = #"{"pid":50,"workspaceFolders":["/work/app","/work/app/sub"],"ideName":"IntelliJ IDEA","authToken":"SECRET","transport":"ws"}"#
        try Data(lock.utf8).write(to: dir.appendingPathComponent("1234.lock"))
        let dead = #"{"pid":51,"workspaceFolders":["/work/other"],"ideName":"Dead"}"#
        try Data(dead.utf8).write(to: dir.appendingPathComponent("1235.lock"))
        let r = resolver([50: .init(name: "idea"), 10: .init(ppid: 1)], ide: dir)
        #expect(r.resolve(pid: 10, tty: "ttys001", cwd: "/work/app/sub/x") == .ide(pid: 50, name: "IntelliJ IDEA"))
        #expect(r.resolve(pid: 10, tty: "ttys001", cwd: "/work/app") == .ide(pid: 50, name: "IntelliJ IDEA"))
        #expect(r.resolve(pid: nil, tty: nil, cwd: "/work/app") == .ide(pid: 50, name: "IntelliJ IDEA"))
        #expect(r.resolve(pid: 10, tty: "ttys001", cwd: "/work/application") == .unknown)   // prefix is not a path prefix
        #expect(r.resolve(pid: 10, tty: "ttys001", cwd: "/work/other") == .unknown)         // IDE pid is gone
    }

    @Test func terminalChainBeatsAnIdeLockButAnIdeAncestorWins() throws {
        let dir = try emptyDir()
        let lock = #"{"pid":50,"workspaceFolders":["/work/app"],"ideName":"IntelliJ IDEA"}"#
        try Data(lock.utf8).write(to: dir.appendingPathComponent("1.lock"))
        let iterm = resolver([
            50: .init(name: "idea", path: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
            10: .init(name: "claude", ppid: 9), 9: .init(name: "zsh", ppid: 8),
            8: .init(name: "iTerm2", ppid: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ], ide: dir)
        #expect(iterm.resolve(pid: 10, tty: "ttys004", cwd: "/work/app") == .iTerm2(tty: "ttys004"))
        let embedded = resolver([
            10: .init(name: "claude", ppid: 9), 9: .init(name: "zsh", ppid: 50),
            50: .init(name: "idea", ppid: 1, path: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
        ], ide: dir)
        #expect(embedded.resolve(pid: 10, tty: "ttys004", cwd: "/work/app") == .ide(pid: 50, name: "IntelliJ IDEA"))
    }

    @Test func electronHelperResolvesToTheOutermostBundle() throws {
        let dir = try emptyDir()
        let helper = "/Applications/IntelliJ IDEA.app/Contents/Frameworks/IntelliJ Helper.app/Contents/MacOS/IntelliJ Helper"
        let r = resolver([10: .init(ppid: 8), 8: .init(name: "helper", path: helper)], ide: dir)
        #expect(r.resolve(pid: 10, tty: nil, cwd: "/p") == .app(bundleId: "com.jetbrains.intellij", pid: 8))
        // A failed lookup keeps walking up to a resolvable ancestor.
        let walk = resolver([
            10: .init(ppid: 8),
            8: .init(name: "ghost", ppid: 7, path: "/Applications/Ghost.app/Contents/MacOS/ghost"),
            7: .init(name: "idea", path: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
        ], ide: dir)
        #expect(walk.resolve(pid: 10, tty: nil, cwd: "/p") == .app(bundleId: "com.jetbrains.intellij", pid: 7))
    }

    @Test func jumpPlanTable() {
        #expect(AgentJumpPlan.plan(for: .iTerm2(tty: "ttys1"), fallbackBundleId: nil)
            == .terminalTab(bundleId: "com.googlecode.iterm2", tty: "ttys1"))
        #expect(AgentJumpPlan.plan(for: .terminalApp(tty: "ttys2"), fallbackBundleId: "x")
            == .terminalTab(bundleId: "com.apple.Terminal", tty: "ttys2"))
        #expect(AgentJumpPlan.plan(for: .tmux(paneTty: "ttys3"), fallbackBundleId: nil) == .tmuxPane(paneTty: "ttys3"))
        #expect(AgentJumpPlan.plan(for: .ide(pid: 5, name: "n"), fallbackBundleId: nil) == .activate(pid: 5))
        #expect(AgentJumpPlan.plan(for: .app(bundleId: "b", pid: 6), fallbackBundleId: nil) == .activate(pid: 6))
        #expect(AgentJumpPlan.plan(for: .unknown, fallbackBundleId: nil) == .cannotLocate)
        #expect(AgentJumpPlan.plan(for: .unknown, fallbackBundleId: "") == .cannotLocate)
        #expect(AgentJumpPlan.plan(for: .unknown, fallbackBundleId: "com.x") == .activateBundle("com.x"))
        #expect(AgentJumpPlan.plan(for: .herdr, fallbackBundleId: "com.x") == .activateBundle("com.x"))
    }

    @Test func ttyScriptsEscapeAndTargetTheRightProperty() {
        let iterm = TerminalTTYScript.script(iTerm2: true, tty: "ttys004")
        #expect(iterm.contains(#"tty of s is "/dev/ttys004""#) && iterm.contains("tell application \"iTerm2\""))
        let term = TerminalTTYScript.script(iTerm2: false, tty: "ttys004")
        #expect(term.contains(#"tty of t is "/dev/ttys004""#) && term.contains("tell application \"Terminal\""))
        let hostile = TerminalTTYScript.script(iTerm2: false, tty: #"x" & (do shell script "id") & "\"#)
        #expect(hostile.contains(#"/dev/x\" & (do shell script \"id\") & \"\\""#))
        #expect(TerminalTTYScript.escapedLiteral(#"a\"b"#) == #"a\\\"b"#)
    }

    @Test func tmuxPaneAndClientParsing() throws {
        let panes = "/dev/ttys020 main:0.0\n/dev/ttys021 my work:2.1\n"
        let pane = try #require(TmuxJump.findPane(tty: "ttys021", in: panes))
        #expect(pane.session == "my work" && pane.window == "2" && pane.pane == "1")
        #expect(pane.paneTarget == "my work:2.1")
        #expect(TmuxJump.findPane(tty: "ttys099", in: panes) == nil)

        let clients = "/dev/ttys030 111 other\n/dev/ttys031 222 my work\n"
        #expect(TmuxJump.pickClient(for: "my work", in: clients)?.tty == "ttys031")
        #expect(TmuxJump.pickClient(for: "zzz", in: clients)?.pid == 111)
        #expect(TmuxJump.pickClient(for: "a", in: "") == nil)

        let cmds = TmuxJump.selectCommands(pane: pane, client: TmuxJump.pickClient(for: "my work", in: clients))
        #expect(cmds == [
            ["switch-client", "-c", "/dev/ttys031", "-t", "my work"],
            ["select-window", "-t", "my work:2"],
            ["select-pane", "-t", "my work:2.1"],
        ])
        #expect(TmuxJump.selectCommands(pane: pane, client: nil)[0] == ["switch-client", "-t", "my work"])
    }
}
