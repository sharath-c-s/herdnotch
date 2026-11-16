import Foundation
import HerdKit
import Testing

struct PreviewTextTests {
    @Test func shortTextIsUntouched() {
        #expect(PreviewText.rows(["mkfifo a"], columns: 60, maxRows: 4) == ["mkfifo a"])
    }

    @Test func longLineWrapsWithoutLosingCharacters() {
        let line = (0..<30).map { "word\($0)" }.joined(separator: " ")
        let rows = PreviewText.rows([line], columns: 40, maxRows: 100)
        #expect(rows.allSatisfy { $0.count <= 40 })
        #expect(rows.joined(separator: " ") == line)
    }

    @Test func unbrokenLineHardCuts() {
        let rows = PreviewText.rows([String(repeating: "x", count: 100)], columns: 40, maxRows: 10)
        #expect(rows.map(\.count) == [40, 40, 20])
    }

    @Test func overflowEndsWithMoreMarkerCountingHiddenChars() {
        let rows = PreviewText.rows([String(repeating: "x", count: 100)], columns: 40, maxRows: 2)
        #expect(rows == [String(repeating: "x", count: 40), "\u{2026} 60 more chars, Jump to see all"])
    }

    @Test func singleRowOverflowStillSaysHowMuchIsHidden() {
        let rows = PreviewText.rows([String(repeating: "x", count: 100)], columns: 40, maxRows: 1)
        #expect(rows == ["\u{2026} 100 more chars, Jump to see all"])
    }

    @Test func maxInputWrapsFastAndCountsEveryHiddenChar() {
        // Space-free lines hard-cut exactly, so every hidden character is predictable.
        let lines = Array(repeating: String(repeating: "x", count: PreviewText.maxLineCharacters), count: PreviewText.maxInputLines)
        let clock = ContinuousClock()
        var rows: [String] = []
        let elapsed = clock.measure { rows = PreviewText.rows(lines, columns: 40, maxRows: 4) }
        #expect(elapsed < .milliseconds(500))
        let hidden = PreviewText.maxInputLines * PreviewText.maxLineCharacters - 3 * 40
        #expect(rows == Array(repeating: String(repeating: "x", count: 40), count: 3) + ["\u{2026} \(hidden) more chars, Jump to see all"])
    }

    @Test func charsCutByTheLineCapAreStillCounted() {
        let rows = PreviewText.rows([String(repeating: "x", count: 5000)], columns: 4000, maxRows: 8)
        #expect(rows == [String(repeating: "x", count: 4000), "\u{2026} 1000 more chars, Jump to see all"])
    }

    @Test func linesBeyondTheInputCapAreCountedNotWrapped() {
        let lines = Array(repeating: "abc", count: PreviewText.maxInputLines + 2)
        let rows = PreviewText.rows(lines, columns: 40, maxRows: PreviewText.maxInputLines + 1)
        #expect(rows.count == PreviewText.maxInputLines + 1)
        #expect(rows.last == "\u{2026} 6 more chars, Jump to see all")
    }

    @Test func alwaysHelpNamesWhatIsRemembered() throws {
        let rule = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkfifo x"}]}"#.utf8))
        #expect(PreviewText.alwaysHelp(rule) == "Always allow Bash(mkfifo x)")
        let mode = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"setMode","mode":"auto"}"#.utf8))
        #expect(PreviewText.alwaysHelp(mode) == "Switch to auto mode")
        #expect(PreviewText.alwaysHelp(.object(["type": .string("other")])) == "other")
        #expect(PreviewText.alwaysHelp(nil) == "Allow and remember the suggested rule")
    }

    @Test func keepTailKeepsLastRows() {
        #expect(PreviewText.rows(["a", "b", "c", "d"], columns: 40, maxRows: 2, keepTail: true) == ["c", "d"])
    }

    @Test func shortLabelCutsAtColonOrDot() {
        #expect(PreviewText.shortLabel("Yes, and don\u{2019}t ask again for: mkfifo x *") == "Yes, and don\u{2019}t ask again")
        #expect(PreviewText.shortLabel("Yes, and switch to auto mode \u{00B7} handles these") == "Yes, and switch to auto mode")
        #expect(PreviewText.shortLabel("No") == "No")
    }

    @Test func hookLinesKeepFullBashCommandAndGenericKeys() {
        let long = String(repeating: "a", count: 200)
        #expect(PreviewText.hookLines(toolName: "Bash", input: ["command": long]) == [long])
        let lines = PreviewText.hookLines(toolName: "WebFetch", input: ["url": long, "n": 3])
        #expect(lines == ["n: 3", "url: \(long)"])
    }

    @Test func flowRowsWraps() {
        #expect(PreviewText.flowRows(widths: [100, 100, 100], available: 320, spacing: 6) == 1)
        #expect(PreviewText.flowRows(widths: [100, 100, 100], available: 250, spacing: 6) == 2)
        #expect(PreviewText.flowRows(widths: [], available: 250, spacing: 6) == 0)
    }
}
