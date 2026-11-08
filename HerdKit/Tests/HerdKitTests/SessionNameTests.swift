import Foundation
@testable import HerdKit
import Testing

struct SessionNameTests {
    private func agent(
        kind: String = "claude", cwd: String = "/p/cwd-dir", tab: String? = nil, name: String? = nil,
        source: String? = nil, sessionId: String? = nil, title: String? = nil
    ) -> HerdAgent {
        HerdAgent(
            agent: kind, agentStatus: .idle, cwd: cwd, paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1",
            agentSessionID: sessionId, terminalTitle: title.map { "✳ \($0)" }, terminalTitleStripped: title, tabLabel: tab, claudeSessionName: name,
            claudeSessionNameSource: source)
    }

    private func entry(_ id: String, name: String, source: String) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: 1, sessionId: id, cwd: "/p", name: name, nameSource: source, status: "idle", procStart: nil)
    }

    private func session(_ agents: [HerdAgent]) -> HerdSession {
        HerdSession(
            name: "default", isDefault: true, running: true, socketPath: "/s",
            workspaces: [HerdWorkspace(workspaceId: "w1", label: "w1", agentStatus: .idle, agents: agents)])
    }

    @Test func registryParsesNameSource() throws {
        let json = #"{"pid":7,"sessionId":"s","cwd":"/p","name":"nightly-Fups","nameSource":"user"}"#
        #expect(try #require(ClaudeSessionRegistry.parse(Data(json.utf8))).nameSource == "user")
        let bare = #"{"pid":7,"sessionId":"s","cwd":"/p"}"#
        #expect(try #require(ClaudeSessionRegistry.parse(Data(bare.utf8))).nameSource == "")
    }

    @Test func displayNameOrder() {
        #expect(agent(tab: "tab", name: "mine", source: "user").displayName == "mine")
        #expect(agent(tab: "tab", name: "auto-title", source: "auto").displayName == "auto-title")
        #expect(agent(tab: "tab", name: "cost-analysis-96", source: "derived").displayName == "tab")
        #expect(agent(name: "cost-analysis-96", source: "derived").displayName == "cost-analysis-96")
        #expect(agent().displayName == "cwd-dir")
        #expect(agent(tab: "", name: "", source: "user").displayName == "cwd-dir")
        #expect(agent(tab: "tab", name: "", source: "user").displayName == "tab")
    }

    @Test func claudeTerminalTitleBeatsTabAndDerivedName() {
        #expect(agent(tab: "tab", name: "mine", source: "user", title: "Live title").displayName == "mine")
        #expect(agent(tab: "tab", name: "bar-02", source: "derived", title: "Live title").displayName == "Live title")
        #expect(agent(tab: "1", title: "shara-brewer").displayName == "shara-brewer")
        #expect(agent(kind: "codex", tab: "tab", title: "codex").displayName == "tab")
        #expect(agent(tab: "tab", title: "").displayName == "tab")
    }

    @Test func titleWithoutClaudeGlyphOrPlaceholderIsIgnored() {
        #expect(agent(tab: "1", name: "bar-02", source: "derived", title: "Claude Code").displayName == "bar-02")
        let shellOwned = HerdAgent(
            agent: "claude", agentStatus: .idle, cwd: "/p/cwd-dir", paneId: "w1:p1", tabId: "w1:t1",
            workspaceId: "w1", terminalTitle: "zsh", terminalTitleStripped: "zsh", tabLabel: "1")
        #expect(shellOwned.displayName == "cwd-dir")
    }

    @Test func numericTabLabelIsSkipped() {
        #expect(agent(tab: "2", name: "make-me-money-b6", source: "derived").displayName == "make-me-money-b6")
        #expect(agent(tab: "3").displayName == "cwd-dir")
        #expect(agent(tab: "v2").displayName == "v2")
        #expect(agent(tab: "三").displayName == "三")
    }

    @Test func decodesTerminalTitleFromAgentList() throws {
        let json = #"{"agent":"claude","agent_status":"idle","cwd":"/p","focused":false,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_title":"✳ shara-brewer","terminal_title_stripped":"shara-brewer"}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try d.decode(HerdAgent.self, from: Data(json.utf8)).displayName == "shara-brewer")
        let bare = #"{"agent":"claude","agent_status":"idle","cwd":"/p/cwd-dir","focused":false,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}"#
        #expect(try d.decode(HerdAgent.self, from: Data(bare.utf8)).displayName == "cwd-dir")
    }

    @Test func herdrAgentIsNamedBySessionIdMatch() {
        let sessions = [session([agent(tab: "tab", sessionId: "abc"), agent(tab: "other", sessionId: "zzz")])]
        let out = AgentSourceMerge.named(sessions, entries: [entry("abc", name: "nightly-Fups", source: "user")])
        let agents = out[0].workspaces[0].agents
        #expect(agents[0].displayName == "nightly-Fups" && agents[0].tabLabel == "tab")
        #expect(agents[1].displayName == "other" && agents[1].claudeSessionName == nil)
    }

    @Test func noRegistryMatchLeavesTabLabel() {
        let sessions = [session([agent(tab: "tab", sessionId: "abc")])]
        let out = AgentSourceMerge.named(sessions, entries: [entry("nope", name: "x", source: "user")])
        #expect(out[0].workspaces[0].agents[0] == sessions[0].workspaces[0].agents[0])
    }

    @Test func searchFindsSessionName() {
        let named = agent(tab: "tab", name: "nightly-Fups", source: "user")
        let pane = HerdPane(session: session([named]), workspaceLabel: "w1", agent: named)
        #expect(HerdPaneSearch.rank([pane], query: "nightly").count == 1)
        #expect(HerdPaneSearch.text(of: .tabLabel, for: pane) == "nightly-Fups")
    }

    @Test func searchStillFindsHerdrTabBehindClaudeName() throws {
        let named = agent(tab: "catalog_diff", name: "nightly", source: "user")
        let pane = HerdPane(session: session([named]), workspaceLabel: "w1", agent: named)
        #expect(HerdPaneSearch.rank([pane], query: "nightly").first?.matchedField == .tabLabel)
        #expect(try #require(HerdPaneSearch.rank([pane], query: "catalog").first).matchedField == .herdrTab)
    }

    @Test func herdrTabFieldIsEmptyWhenTabIsTheDisplayName() {
        let plain = agent(tab: "tab")
        let pane = HerdPane(session: session([plain]), workspaceLabel: "w1", agent: plain)
        #expect(HerdPaneSearch.text(of: .herdrTab, for: pane).isEmpty)
        #expect(HerdPaneSearch.rank([pane], query: "tab").first?.matchedField == .tabLabel)
    }
}
