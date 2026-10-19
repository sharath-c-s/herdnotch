import Foundation
@testable import HerdKit
import Testing

struct SessionNameTests {
    private func agent(
        cwd: String = "/p/cwd-dir", tab: String? = nil, name: String? = nil, source: String? = nil,
        sessionId: String? = nil
    ) -> HerdAgent {
        HerdAgent(
            agent: "claude", agentStatus: .idle, cwd: cwd, paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1",
            agentSessionID: sessionId, tabLabel: tab, claudeSessionName: name, claudeSessionNameSource: source)
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
