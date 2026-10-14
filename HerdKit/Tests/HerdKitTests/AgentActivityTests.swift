import Foundation
import HerdKit
import Testing

struct AgentActivityTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any], usage: [String: Int]? = nil,
        model: String = "claude-opus-5-5", sidechain: Bool = false) -> String
    {
        var message: [String: Any] = [
            "model": model, "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
        ]
        if let usage { message["usage"] = usage }
        return json(["type": "assistant", "isSidechain": sidechain, "message": message])
    }

    private func result(_ id: String) -> String {
        json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    private func assistantText(usage: [String: Int], sidechain: Bool = false, model: String = "claude-opus-5-5",
        stop: String = "end_turn") -> String
    {
        json([
            "type": "assistant", "isSidechain": sidechain,
            "message": ["model": model, "stop_reason": stop, "usage": usage, "content": [["type": "text", "text": "hi"]]],
        ])
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    private func activity(_ lines: [String]) throws -> AgentActivity {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write(lines, to: url)
        return TranscriptReader(url: url).read()
    }

    // MARK: - Tool targets

    @Test func targetRules() throws {
        let cases: [(String, [String: Any], String)] = [
            ("Edit", ["file_path": "/a/b/NotchToast.swift"], "Edit NotchToast.swift"),
            ("Write", ["file_path": "/a/b/x.md"], "Write x.md"),
            ("Read", ["file_path": "/a/b/y.txt"], "Read y.txt"),
            ("NotebookEdit", ["file_path": "/a/n.ipynb"], "NotebookEdit n.ipynb"),
            ("Bash", ["command": "swift test\nfoo", "description": "Run tests"], "Bash Run tests"),
            ("Bash", ["command": "swift test\nfoo"], "Bash swift test"),
            ("Grep", ["pattern": "foo.*bar"], "Grep foo.*bar"),
            ("Glob", ["pattern": "**/*.swift"], "Glob **/*.swift"),
            ("Agent", ["description": "Adversarial verify"], "Agent Adversarial verify"),
            ("Skill", ["skill": "judge"], "Skill judge"),
            ("WebFetch", ["url": "https://example.com/a/b"], "WebFetch example.com"),
            ("WebSearch", ["query": "swift tail"], "WebSearch swift tail"),
            ("ToolSearch", ["query": "select:x"], "ToolSearch"),
            ("Mystery", ["x": 1], "Mystery"),
        ]
        for (name, input, expected) in cases {
            let a = try activity([toolUse("t1", name, input)])
            #expect(a.currentTool?.display == expected)
        }
    }

    @Test func targetTruncatedToOneShortLine() throws {
        let a = try activity([toolUse("t1", "Bash", ["command": String(repeating: "x", count: 200)])])
        #expect((a.currentTool?.target?.count ?? 0) <= 48)
        #expect(a.currentTool?.target?.hasSuffix("\u{2026}") == true)
    }

    // MARK: - Pending

    @Test func resolvedToolIsNotCurrent() throws {
        let a = try activity([toolUse("t1", "Bash", ["command": "ls"]), result("t1")])
        #expect(a.currentTool == nil)
        #expect(a.pendingAsk == nil)
    }

    @Test func newestUnresolvedToolWins() throws {
        let a = try activity([
            toolUse("t1", "Read", ["file_path": "/a.txt"]),
            toolUse("t2", "Edit", ["file_path": "/b.swift"]),
            result("t2"),
        ])
        #expect(a.currentTool?.display == "Read a.txt")
    }

    @Test func pendingAskText() throws {
        let q = try activity([toolUse("t", "AskUserQuestion", ["questions": [["question": "Which layout?"]]])])
        #expect(q.pendingAsk == "asks: Which layout?")
        let b = try activity([toolUse("t", "Bash", ["command": "rm -rf build/\necho"])])
        #expect(b.pendingAsk == "wants to run: rm -rf build/")
        let e = try activity([toolUse("t", "Edit", ["file_path": "/x/main.swift"])])
        #expect(e.pendingAsk == "wants to edit main.swift")
        let w = try activity([toolUse("t", "Write", ["file_path": "/x/new.swift"])])
        #expect(w.pendingAsk == "wants to edit new.swift")
        let o = try activity([toolUse("t", "WebFetch", ["url": "https://a.b"])])
        #expect(o.pendingAsk == "wants to use WebFetch")
    }

    // MARK: - Context

    @Test func contextTokensFromLatestRowIgnoringSidechain() throws {
        let a = try activity([
            assistantText(usage: ["input_tokens": 1, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 10]),
            assistantText(usage: ["input_tokens": 2, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 20]),
            assistantText(usage: ["input_tokens": 9, "cache_read_input_tokens": 9_999, "cache_creation_input_tokens": 9], sidechain: true),
        ])
        #expect(a.contextTokens == 222)
        #expect(a.contextLimit == 200_000)
    }

    @Test func syntheticAndZeroUsageRowsKeepContext() throws {
        let real = assistantText(usage: ["input_tokens": 1, "cache_read_input_tokens": 100_000], model: "claude-opus-5-5[1m]")
        let synthetic = assistantText(
            usage: ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0], model: "<synthetic>")
        let a = try activity([real, synthetic])
        #expect(a.contextTokens == 100_001)
        #expect(a.contextLimit == 1_000_000)  // model tag from the real row survives
        let zero = try activity([real, assistantText(usage: ["input_tokens": 0], model: "claude-opus-5-5")])
        #expect(zero.contextTokens == 100_001)
    }

    @Test func contextLimitHeuristic() throws {
        let big = try activity([assistantText(usage: ["input_tokens": 1, "cache_read_input_tokens": 250_000])])
        #expect(big.contextLimit == 1_000_000)
        // Max observed sticks even after the latest turn is smaller (post-compaction).
        let shrunk = try activity([
            assistantText(usage: ["input_tokens": 1, "cache_read_input_tokens": 250_000]),
            assistantText(usage: ["input_tokens": 1, "cache_read_input_tokens": 5_000]),
        ])
        #expect(shrunk.contextLimit == 1_000_000)
        #expect(shrunk.contextTokens == 5_001)
        let tagged = try activity([assistantText(usage: ["input_tokens": 1], model: "claude-opus-5-5[1m]")])
        #expect(tagged.contextLimit == 1_000_000)
    }

    // MARK: - Incremental reading

    @Test func incrementalReadAcrossAppendsWithSplitLine() throws {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write([toolUse("t1", "Read", ["file_path": "/a.txt"])], to: url)
        let reader = TranscriptReader(url: url)
        #expect(reader.read().currentTool?.display == "Read a.txt")

        let second = toolUse("t2", "Edit", ["file_path": "/b.swift"]) + "\n"
        let cut = second.index(second.startIndex, offsetBy: 30)
        try append(String(second[..<cut]), to: url)
        #expect(reader.read().currentTool?.display == "Read a.txt")  // partial line held back
        try append(String(second[cut...]), to: url)
        #expect(reader.read().currentTool?.display == "Edit b.swift")
        try append(result("t2") + "\n", to: url)
        #expect(reader.read().currentTool?.display == "Read a.txt")
    }

    @Test func tailStartDropsPartialFirstLine() throws {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        // Early line far outside the 2 MiB window, then padding, then a recent line.
        let early = toolUse("old", "Read", ["file_path": "/old.txt"])
        let padding = json(["type": "attachment", "blob": String(repeating: "z", count: 1_000_000)])
        try write([early, padding, padding, padding, toolUse("new", "Edit", ["file_path": "/new.swift"])], to: url)
        let a = TranscriptReader(url: url).read()
        #expect(a.currentTool?.display == "Edit new.swift")
    }

    @Test func largeGapIsTreatedAsFreshStart() throws {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write([toolUse("old", "Read", ["file_path": "/old.txt"], usage: ["input_tokens": 5])], to: url)
        let reader = TranscriptReader(url: url)
        #expect(reader.read().currentTool?.display == "Read old.txt")
        let padding = json(["type": "attachment", "blob": String(repeating: "z", count: 1_000_000)])
        try append([padding, padding, padding, toolUse("new", "Edit", ["file_path": "/new.swift"])].joined(separator: "\n") + "\n", to: url)
        let a = reader.read()
        #expect(a.currentTool?.display == "Edit new.swift")
        #expect(a.contextTokens == nil)  // old state dropped, only the tail was parsed
    }

    @Test func pendingCapKeepsNewest() throws {
        let lines = (0..<80).map { toolUse("t\($0)", "Read", ["file_path": "/f\($0).txt"]) }
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write(lines, to: url)
        let reader = TranscriptReader(url: url)
        #expect(reader.read().currentTool?.display == "Read f79.txt")
        // Resolve the 64 newest; the 16 oldest were evicted, so nothing is left pending.
        try append((16..<80).map { result("t\($0)") }.joined(separator: "\n") + "\n", to: url)
        #expect(reader.read().currentTool == nil)
    }

    @Test func multibyteCharacterSplitAcrossAppends() throws {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write([], to: url)
        let reader = TranscriptReader(url: url)
        let bytes = Array((toolUse("t1", "Grep", ["pattern": "caf\u{E9}\u{1F600}"]) + "\n").utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1  // between the two bytes of "\u{E9}"
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(bytes[..<split]))
        #expect(reader.read().currentTool == nil)
        try h.write(contentsOf: Data(bytes[split...]))
        try h.close()
        #expect(reader.read().currentTool?.display == "Grep caf\u{E9}\u{1F600}")
    }

    @Test func truncationResets() throws {
        let url = try tempDir().appendingPathComponent("t.jsonl")
        try write([toolUse("t1", "Read", ["file_path": "/a.txt"]), toolUse("t2", "Read", ["file_path": "/b.txt"])], to: url)
        let reader = TranscriptReader(url: url)
        #expect(reader.read().currentTool?.display == "Read b.txt")
        try write([toolUse("t3", "Grep", ["pattern": "x"])], to: url)
        #expect(reader.read().currentTool?.display == "Grep x")
    }

    @Test func malformedLineIsSkipped() throws {
        let a = try activity(["{not json", toolUse("t1", "Read", ["file_path": "/a.txt"]), "[1,2"])
        #expect(a.currentTool?.display == "Read a.txt")
    }

    @Test func plainStringUserContentIsIgnored() throws {
        let prompt = json(["type": "user", "message": ["content": "hello"]])
        let a = try activity([toolUse("t1", "Read", ["file_path": "/a.txt"]), prompt])
        #expect(a.currentTool?.display == "Read a.txt")
    }

    // MARK: - Subagents

    @Test func subagentCounting() throws {
        let dir = try tempDir()
        let running = dir.appendingPathComponent("agent-a.jsonl")
        let finished = dir.appendingPathComponent("agent-b.jsonl")
        let stale = dir.appendingPathComponent("agent-c.jsonl")
        let other = dir.appendingPathComponent("agent-a.meta.json")
        try write([toolUse("t", "Read", ["file_path": "/x"])], to: running)
        try write([toolUse("t", "Read", ["file_path": "/x"]), assistantText(usage: ["input_tokens": 1])], to: finished)
        try write([toolUse("t", "Read", ["file_path": "/x"])], to: stale)
        try write(["{}"], to: other)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: stale.path)
        #expect(SubagentCounter.count(in: dir) == 1)
        #expect(SubagentCounter.count(in: dir.appendingPathComponent("missing")) == 0)
    }

    @Test func subagentWithHugeLastLineIsFinished() throws {
        let dir = try tempDir()
        let huge = json([
            "type": "assistant",
            "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": String(repeating: "x", count: 100_000)]]],
        ])
        try write([toolUse("t", "Read", ["file_path": "/x"]), huge], to: dir.appendingPathComponent("agent-a.jsonl"))
        #expect(SubagentCounter.count(in: dir) == 0)
    }

    // MARK: - Text hygiene

    @Test func mcpNamesShortenAndLongNamesTruncate() {
        #expect(ToolSummary(name: "mcp__plugin_acme_acme-services__hermes_get_x", target: nil).display == "hermes_get_x")
        #expect(ToolSummary(name: "mcp__srv__tool", target: "t").display == "tool t")
        let long = ToolSummary(name: String(repeating: "n", count: 200), target: nil).display
        #expect(long.count <= 48)
        #expect(long.hasSuffix("\u{2026}"))
    }

    @Test func askUsesShortenedName() throws {
        let a = try activity([toolUse("t", "mcp__srv__do_thing", [:])])
        #expect(a.pendingAsk == "wants to use do_thing")
    }

    @Test func controlAndBidiCharactersAreStripped() throws {
        let a = try activity([toolUse("t", "Bash", ["command": "echo\u{202E}hi\tthere"])])
        #expect(a.currentTool?.target == "echohi there")
    }

    // MARK: - Locator

    @Test func locatorRejectsUnsafeIds() throws {
        let root = try tempDir()
        let proj = root.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try write(["{}"], to: root.appendingPathComponent("secret.jsonl"))
        let locator = TranscriptLocator(projectsRoot: root)
        for bad in ["", "../secret", "a/b", "a..b", "a\0b"] { #expect(locator.locate(bad) == nil) }
    }

    @Test func locatorFindsAndCaches() throws {
        let root = try tempDir()
        let proj = root.appendingPathComponent("-some-project")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let locator = TranscriptLocator(projectsRoot: root)
        let now = Date()
        #expect(locator.locate("abc", now: now) == nil)
        try write(["{}"], to: proj.appendingPathComponent("abc.jsonl"))
        // Negative cache holds for 30 s, then re-globs.
        #expect(locator.locate("abc", now: now.addingTimeInterval(5)) == nil)
        #expect(locator.locate("abc", now: now.addingTimeInterval(31))?.lastPathComponent == "abc.jsonl")
        try FileManager.default.removeItem(at: proj.appendingPathComponent("abc.jsonl"))
        #expect(locator.locate("abc", now: now.addingTimeInterval(32)) != nil)  // positive cache
    }

    // MARK: - HerdAgent decoding

    private let base = """
        "agent":"claude","agent_status":"working","cwd":"/x","focused":true,"pane_id":"w1:p1",
        "tab_id":"w1:t1","workspace_id":"w1"
        """

    @Test func agentDecodesWithAgentSession() throws {
        let data = Data("""
            {\(base),"agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"49932215"}}
            """.utf8)
        let agent = try HerdJSON.decoder.decode(HerdAgent.self, from: data)
        #expect(agent.agentSessionID == "49932215")
        #expect(agent.agentSessionSource == "herdr:claude")
        let again = try HerdJSON.decoder.decode(HerdAgent.self, from: HerdJSON.encoder.encode(agent))
        #expect(again == agent)
    }

    @Test func agentWithMalformedAgentSessionStillDecodes() throws {
        let data = Data("{\(base),\"agent_session\":\"oops\"}".utf8)
        let agent = try HerdJSON.decoder.decode(HerdAgent.self, from: data)
        #expect(agent.agentSessionID == nil)
        #expect(agent.agentSessionSource == nil)
    }

    @Test func agentDecodesWithoutAgentSession() throws {
        let agent = try HerdJSON.decoder.decode(HerdAgent.self, from: Data("{\(base)}".utf8))
        #expect(agent.agentSessionID == nil)
        #expect(agent.agentSessionSource == nil)
    }
}
