import Foundation
import HerdKit
import Testing

struct ToolPreviewTests {
    private func preview(_ name: String, _ input: [String: Any], max: Int = 6) -> [String] {
        ToolSummarizer.previewLines(name: name, input: input, maxLines: max)
    }

    @Test func bashShowsCommandLinesCapped() {
        #expect(preview("Bash", ["command": "echo a\necho b"]) == ["echo a", "echo b"])
        #expect(preview("Bash", ["command": "1\n2\n3\n4\n5\n6\n7\n8"]).count == 6)
        #expect(preview("Bash", ["command": "1\n2\n3"], max: 2) == ["1", "2"])
        #expect(preview("Bash", ["command": String(repeating: "x", count: 100)])[0].hasSuffix("\u{2026}"))
    }

    @Test func widthParameterWidensTruncation() {
        let long = String(repeating: "x", count: 60)
        #expect(!ToolSummarizer.previewLines(name: "Bash", input: ["command": long], width: 70)[0].hasSuffix("\u{2026}"))
        #expect(ToolSummarizer.previewLines(name: "Bash", input: ["command": long], width: 20)[0].count == 20)
    }

    @Test func editShowsOldAndNewWithThreeLineCap() {
        let lines = preview("Edit", ["old_string": "a\nb\nc\nd", "new_string": "x\ny"])
        #expect(lines == ["- a", "- b", "- c", "+ x", "+ y"])
    }

    @Test func multiEditUsesFirstEdit() {
        let input: [String: Any] = ["edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d"]]]
        #expect(preview("MultiEdit", input) == ["- a", "+ b"])
    }

    @Test func writeShowsPathThenContent() {
        #expect(preview("Write", ["file_path": "/a/b.txt", "content": "l1\nl2"]) == ["/a/b.txt", "l1", "l2"])
    }

    @Test func askUserQuestionShowsQuestionsAndOptions() {
        let input: [String: Any] = ["questions": [["question": "Pick?", "options": [["label": "Red"], ["label": "Blue"]]]]]
        #expect(preview("AskUserQuestion", input) == ["Pick?", "  \u{2022} Red", "  \u{2022} Blue"])
    }

    @Test func otherToolsShowNameAndTarget() {
        #expect(preview("Grep", ["pattern": "foo"]) == ["Grep: foo"])
        #expect(preview("Mystery", [:]) == ["Mystery"])
        #expect(preview("Bash", [:]) == ["Bash"])
    }
}
