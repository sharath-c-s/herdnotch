import Foundation
import HerdKit
import Testing

struct PanePromptTests {
    @Test func bashPermissionIsNumbered() throws {
        let p = try #require(PanePrompt.parse(try paneFixture("pane_claude_bash_permission.txt")))
        #expect(p.options.map(\.number) == [1, 2, 3, 4])
        #expect(p.options.map(\.label).first == "Yes")
        #expect(p.options.last?.label == "No")
        #expect(p.selectedIndex == 0)
        #expect(p.question.last == "Do you want to proceed?")
        #expect(p.question.contains("mkfifo spikepipe_one"))
        #expect(!p.question.contains { $0.hasPrefix("Tip:") || $0.contains("\u{2500}") || $0.contains("\u{254C}") })
        #expect(p.keys(for: 3) == ["4"])
    }

    @Test func askUserQuestionDropsFreeTextAndDescriptions() throws {
        let p = try #require(PanePrompt.parse(try paneFixture("pane_claude_askuserquestion.txt")))
        #expect(p.options.map(\.label) == ["Red", "Blue", "Green"])
        #expect(p.options.map(\.number) == [1, 2, 3])
        #expect(p.question.last == "Pick a colour?")
        #expect(p.keys(for: 1) == ["2"])
    }

    @Test func unnumberedMenuUsesArrowKeys() throws {
        let p = try #require(PanePrompt.parse(try paneFixture("pane_claude_trust_unnumbered.txt")))
        #expect(p.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(p.options.allSatisfy { $0.number == nil })
        #expect(p.selectedIndex == 0)
        #expect(p.keys(for: 1) == ["down", "enter"])
        #expect(p.keys(for: 0) == ["enter"])
    }

    @Test func unnumberedKeysMoveUpFromLowerSelection() {
        let p = PanePrompt(
            question: ["q"],
            options: [.init(label: "a", number: nil), .init(label: "b", number: nil), .init(label: "c", number: nil)],
            selectedIndex: 2)
        #expect(p.keys(for: 0) == ["up", "up", "enter"])
        #expect(p.keys(for: 9) == [])
    }

    @Test func idlePromptIsNotAMenu() throws {
        #expect(PanePrompt.parse(try paneFixture("pane_idle_claude.txt")) == nil)
        #expect(PanePrompt.parse("") == nil)
    }

    @Test func fingerprintIsStableAcrossReads() throws {
        let text = try paneFixture("pane_claude_bash_permission.txt")
        let a = try #require(PanePrompt.parse(text))
        let b = try #require(PanePrompt.parse(text))
        #expect(a.fingerprint == b.fingerprint)
        let other = try #require(PanePrompt.parse(try paneFixture("pane_claude_askuserquestion.txt")))
        #expect(a.fingerprint != other.fingerprint)
    }

    @Test func fingerprintCoversEverythingAboveTheMenu() throws {
        func menu(_ command: String) -> String {
            "Bash command\n \(command)\n line two\n line three\n same last line\n\n Do you want to proceed?\n \u{276F} 1. Yes\n   2. No\n"
        }
        let a = try #require(PanePrompt.parse(menu("rm -rf a")))
        let b = try #require(PanePrompt.parse(menu("rm -rf b")))
        #expect(a.question == b.question)
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func answerKeysRejectStaleOrUnparsablePane() throws {
        let shown = try #require(PanePrompt.parse(try paneFixture("pane_claude_bash_permission.txt")))
        let other = try paneFixture("pane_claude_askuserquestion.txt")
        #expect(PanePrompt.answerKeys(fresh: other, shown: shown, optionIndex: 0) == nil)
        #expect(PanePrompt.answerKeys(fresh: try paneFixture("pane_idle_claude.txt"), shown: shown, optionIndex: 0) == nil)
        #expect(PanePrompt.cancelKeys(fresh: other, shown: shown) == nil)
    }

    @Test func answerKeysForSamePromptUseTheDigit() throws {
        let text = try paneFixture("pane_claude_bash_permission.txt")
        let shown = try #require(PanePrompt.parse(text))
        #expect(PanePrompt.answerKeys(fresh: text, shown: shown, optionIndex: 3) == ["4"])
        #expect(PanePrompt.cancelKeys(fresh: text, shown: shown) == ["esc"])
    }

    @Test func unnumberedAnswerUsesFreshSelectionAfterItMoved() throws {
        let text = try paneFixture("pane_claude_trust_unnumbered.txt")
        let shown = try #require(PanePrompt.parse(text))
        #expect(shown.selectedIndex == 0)
        let moved = text.replacingOccurrences(of: "\u{276F} No, exit", with: "  No, exit")
            .replacingOccurrences(of: "  Yes, I trust this folder", with: "\u{276F} Yes, I trust this folder")
        #expect(PanePrompt.answerKeys(fresh: moved, shown: shown, optionIndex: 0) == ["up", "enter"])
        #expect(PanePrompt.answerKeys(fresh: moved, shown: shown, optionIndex: 1) == ["enter"])
    }

    @Test func lastMenuWinsAndSelectionIsTracked() throws {
        let text = "Old?\n 1. A\n 2. B\n\nNew?\n   1. X\n \u{276F} 2. Y\n"
        let p = try #require(PanePrompt.parse(text))
        #expect(p.options.map(\.label) == ["X", "Y"])
        #expect(p.selectedIndex == 1)
        #expect(p.question == ["Old?", " 1. A", " 2. B", "New?"].suffix(3).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    @Test func singleOptionIsNotAMenu() {
        #expect(PanePrompt.parse("Pick\n\u{276F} 1. Only\n") == nil)
    }

    @Test func denyKeysIsEscape() {
        #expect(PanePrompt.denyKeys == ["esc"])
    }
}
