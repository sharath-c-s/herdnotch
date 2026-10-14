import Testing

@testable import HerdPanelUI

struct AgentRowDetailTests {

    @Test func defaultSessionIsOmitted() {
        #expect(agentRowDetail(sessionName: "default", kind: "codex", activityText: nil) == "codex")
    }

    @Test func claudeKindIsOmitted() {
        #expect(agentRowDetail(sessionName: "hail_mary", kind: "claude", activityText: nil) == "hail_mary")
    }

    @Test func nothingLeftIsNil() {
        #expect(agentRowDetail(sessionName: "default", kind: "claude", activityText: nil) == nil)
        #expect(agentRowDetail(sessionName: "default", kind: "claude", activityText: "") == nil)
    }

    @Test func allThreePartsJoinInOrder() {
        #expect(
            agentRowDetail(sessionName: "hail_mary", kind: "codex", activityText: "Editing foo.swift")
                == "hail_mary · codex · Editing foo.swift")
    }

    @Test func activityOnly() {
        #expect(agentRowDetail(sessionName: "default", kind: "claude", activityText: "thinking…") == "thinking…")
    }
}
