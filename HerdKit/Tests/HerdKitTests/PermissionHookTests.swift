import Foundation
import HerdKit
import Testing

struct PermissionHookTests {
    private func request(_ name: String) throws -> HookRequest {
        try JSONDecoder().decode(HookRequest.self, from: Fixture.data(name))
    }

    private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    // MARK: - Decoding

    @Test func decodesBashFixture() throws {
        let r = try request("last_input_Bash")
        #expect(r.sessionID == "899138cf-e275-4049-9efc-fdd25ba3ec16")
        #expect(r.toolName == "Bash")
        #expect(r.permissionSuggestions.count == 1)
        guard case .object(let input) = r.toolInput else { Issue.record("not object"); return }
        #expect(input["command"] == .string("mkfifo spikepipe_two"))
    }

    @Test func decodesAskUserQuestionFixtureWithoutSuggestions() throws {
        let r = try request("last_input_AskUserQuestion")
        #expect(r.toolName == "AskUserQuestion")
        #expect(r.permissionSuggestions.isEmpty)
    }

    // MARK: - Rendering

    @Test func allowRendersExactly() throws {
        let out = HookOutput.render(.allow, for: try request("last_input_Bash"))
        #expect(text(out) == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
    }

    @Test func alwaysEmbedsSuggestionVerbatim() throws {
        let r = try request("last_input_Bash")
        let out = HookOutput.render(.always(suggestionIndex: 0), for: r)
        #expect(text(out) == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"mkfifo spikepipe_two","toolName":"Bash"}],"type":"addRules"}]}}}"#)
    }

    @Test func alwaysOutOfRangeIsPlainAllow() throws {
        let r = try request("last_input_Bash")
        #expect(HookOutput.render(.always(suggestionIndex: 5), for: r) == HookOutput.render(.allow, for: r))
        #expect(HookOutput.render(.always(suggestionIndex: -1), for: r) == HookOutput.render(.allow, for: r))
    }

    @Test func denyCarriesEscapedMessage() throws {
        let out = HookOutput.render(.deny(message: "no \"way\"\nnow"), for: try request("last_input_Bash"))
        #expect(text(out) == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no \"way\"\nnow"}}}"#)
        #expect(!text(out).contains("\n"))
    }

    @Test func answersKeepQuestionsAndAddAnswers() throws {
        let r = try request("last_input_AskUserQuestion")
        let out = HookOutput.render(.answers(["Pick a colour?": "Blue"]), for: r)
        let root = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let decision = try #require((root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let input = try #require(decision["updatedInput"] as? [String: Any])
        #expect(input["answers"] as? [String: String] == ["Pick a colour?": "Blue"])
        let questions = try #require(input["questions"] as? [[String: Any]])
        #expect(questions.first?["question"] as? String == "Pick a colour?")
        #expect((questions.first?["options"] as? [Any])?.count == 3)
        #expect(questions.first?["multiSelect"] as? Bool == false)
    }

    @Test func passthroughIsEmpty() throws {
        #expect(HookOutput.render(.passthrough, for: try request("last_input_Bash")).isEmpty)
    }

    // MARK: - Client

    @Test func clientRelaysReplyAndWritesOneLine() throws {
        let stdin = try Fixture.data("last_input_Bash")  // pretty-printed, multi-line
        let reply = Data((#"{"ok":true}"# + "\n").utf8)
        let connector = RecordingConnector(reply: [reply])
        let out = PermissionHookClient.run(stdin: stdin, socketPath: "/s", connector: connector, timeout: 2)
        #expect(text(out) == #"{"ok":true}"#)
        let line = try #require(connector.written.first)
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(HookRequest.self, from: line) == request("last_input_Bash"))
    }

    @Test func clientReassemblesSplitReply() {
        let connector = RecordingConnector(reply: [Data("{\"a\":".utf8), Data("1}\n".utf8)])
        let out = PermissionHookClient.run(stdin: Data("{}".utf8), socketPath: "/s", connector: connector, timeout: 2)
        #expect(text(out) == #"{"a":1}"#)
    }

    @Test func connectFailureYieldsEmpty() {
        let out = PermissionHookClient.run(
            stdin: Data("{}".utf8), socketPath: "/s", connector: RecordingConnector(fail: true), timeout: 2)
        #expect(out.isEmpty)
    }

    @Test func peerCloseYieldsEmpty() {
        let out = PermissionHookClient.run(
            stdin: Data("{}".utf8), socketPath: "/s", connector: RecordingConnector(reply: []), timeout: 2)
        #expect(out.isEmpty)
    }

    @Test func emptyReplyLineYieldsEmpty() {
        let out = PermissionHookClient.run(
            stdin: Data("{}".utf8), socketPath: "/s", connector: RecordingConnector(reply: [Data("\n".utf8)]), timeout: 2)
        #expect(out.isEmpty)
    }

    @Test func invalidStdinYieldsEmptyWithoutConnecting() {
        let connector = RecordingConnector(reply: [Data("{}\n".utf8)])
        let out = PermissionHookClient.run(stdin: Data("not json".utf8), socketPath: "/s", connector: connector, timeout: 2)
        #expect(out.isEmpty)
        #expect(connector.written.isEmpty)
    }

    @Test func stalledPeerTimesOutEmpty() {
        let out = PermissionHookClient.run(
            stdin: Data("{}".utf8), socketPath: "/s", connector: SlowConnector(connectDelay: 0), timeout: 0.2)
        #expect(out.isEmpty)
    }

    @Test func defaultSocketPathIsUnderApplicationSupport() {
        #expect(PermissionHookClient.defaultSocketPath.hasSuffix("/Library/Application Support/HerdNotch/approvals.sock"))
    }
}
