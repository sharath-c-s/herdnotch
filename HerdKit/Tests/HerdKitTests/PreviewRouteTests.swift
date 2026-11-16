import Foundation
import HerdKit
import Testing

struct PreviewRouteTests {
    private func approval(
        tool: String = "Bash", input: JSONValue = .object([:]), suggestions: [JSONValue] = []
    ) -> PendingApproval {
        PendingApproval(
            token: 1,
            request: HookRequest(sessionID: "s", toolName: tool, toolInput: input, permissionSuggestions: suggestions),
            arrivedAt: Date(timeIntervalSince1970: 0))
    }

    private func ask(multiSelect: Bool? = nil, questions: Int = 1) -> JSONValue {
        var q: [String: JSONValue] = [
            "question": .string("Pick?"),
            "options": .array([.object(["label": .string("Red")]), .object(["label": .string("Blue")])]),
        ]
        if let multiSelect { q["multiSelect"] = .bool(multiSelect) }
        return .object(["questions": .array(Array(repeating: .object(q), count: questions))])
    }

    private let menu = "Do it?\n\u{276F} 1. Yes\n  2. No\n"

    @Test func hookWinsOverPane() {
        let a = approval()
        #expect(PreviewRoute.resolve(approval: a, paneText: menu) == .hook(a, canAlways: false, question: nil))
    }

    @Test func canAlwaysNeedsSuggestions() {
        let a = approval(suggestions: [.object(["type": .string("addRules")])])
        #expect(PreviewRoute.resolve(approval: a, paneText: nil) == .hook(a, canAlways: true, question: nil))
    }

    @Test func singleSelectQuestionYieldsChoice() {
        let a = approval(tool: "AskUserQuestion", input: ask())
        let expected = QuestionChoice(question: "Pick?", labels: ["Red", "Blue"])
        #expect(PreviewRoute.resolve(approval: a, paneText: nil) == .hook(a, canAlways: false, question: expected))
    }

    @Test func multiSelectOrMultiQuestionHasNoChoice() {
        let multi = approval(tool: "AskUserQuestion", input: ask(multiSelect: true))
        let two = approval(tool: "AskUserQuestion", input: ask(questions: 2))
        #expect(PreviewRoute.resolve(approval: multi, paneText: nil) == .hook(multi, canAlways: false, question: nil))
        #expect(PreviewRoute.resolve(approval: two, paneText: nil) == .hook(two, canAlways: false, question: nil))
    }

    @Test func explicitSingleSelectFalseStillYieldsChoice() {
        let a = approval(tool: "AskUserQuestion", input: ask(multiSelect: false))
        guard case .hook(_, _, let q) = PreviewRoute.resolve(approval: a, paneText: nil) else {
            Issue.record("expected hook")
            return
        }
        #expect(q?.labels == ["Red", "Blue"])
    }

    @Test func paneMenuRoutesToPane() {
        guard case .pane(let p) = PreviewRoute.resolve(approval: nil, paneText: menu) else {
            Issue.record("expected pane")
            return
        }
        #expect(p.options.map(\.label) == ["Yes", "No"])
    }

    @Test func noMenuOrNoTextIsPreviewOnly() {
        #expect(PreviewRoute.resolve(approval: nil, paneText: "just output\n> ") == .previewOnly)
        #expect(PreviewRoute.resolve(approval: nil, paneText: nil) == .previewOnly)
    }

    @Test func routeKeyChangesWithTheOfferedAction() {
        let hookA = PreviewRoute.resolve(approval: approval(), paneText: nil)
        let hookB = PreviewRoute.resolve(
            approval: PendingApproval(
                token: 2, request: HookRequest(sessionID: "s", toolName: "Bash", toolInput: .object([:])),
                arrivedAt: Date(timeIntervalSince1970: 0)),
            paneText: nil)
        let paneA = PreviewRoute.resolve(approval: nil, paneText: menu)
        let paneB = PreviewRoute.resolve(approval: nil, paneText: "Other?\n\u{276F} 1. Yes\n  2. No\n")
        let keys = [hookA, hookB, paneA, paneB, PreviewRoute.previewOnly].map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(PreviewRoute.resolve(approval: nil, paneText: menu).key == paneA.key)
        #expect(PreviewRoute.resolve(approval: approval(), paneText: nil).key == hookA.key)
        // Moving the selection inside the same prompt keeps the key, so the buttons stay live.
        #expect(PreviewRoute.resolve(approval: nil, paneText: "Do it?\n  1. Yes\n\u{276F} 2. No\n").key == paneA.key)
    }
}
