import Foundation
import HerdKit
import Testing

/// Covers the fuzzy pane search: subsequence semantics, the field weighting, highlight offsets, and
/// the two ordering guarantees the search window depends on (best first, and stable on ties).
///
/// The cases are written against the user's real content, `catalog_version_diff` and
/// `loader_error_classification`, rather than against invented strings, because the whole reason
/// subsequence matching exists here is that the content is snake_case identifiers whose words the user
/// abbreviates.
struct HerdPaneSearchTests {

    // MARK: - Fixtures

    /// Builds a pane without going through a snapshot, so a test can state exactly the four searchable
    /// texts it cares about.
    ///
    /// - Parameters:
    ///   - label: Tab label. Pass `nil` to exercise the `cwd`-basename fallback.
    ///   - cwd: Working directory.
    ///   - kind: Agent program.
    ///   - session: Owning session name.
    ///   - paneId: Pane id, which only has to be unique within the session.
    /// - Returns: A pane ready to hand to ``HerdPaneSearch/rank(_:query:limit:)``.
    private func pane(
        label: String?,
        cwd: String = "/Users/x/playground/thing",
        kind: String = "claude",
        session: String = "hail_mary",
        paneId: String = "w1:p1"
    ) -> HerdPane {
        HerdPane(
            session: HerdSession(
                name: session,
                isDefault: false,
                running: true,
                socketPath: "/tmp/\(session).sock"
            ),
            workspaceLabel: "w1",
            agent: HerdAgent(
                agent: kind,
                agentStatus: .idle,
                cwd: cwd,
                paneId: paneId,
                tabId: "\(paneId).t",
                workspaceId: "w1",
                tabLabel: label
            )
        )
    }

    // MARK: - Subsequence semantics

    /// The headline requirement: an abbreviation made of word initials finds the identifier, which no
    /// substring search would.
    @Test func abbreviationFindsSnakeCaseIdentifier() throws {
        let panes = [pane(label: "catalog_version_diff"), pane(label: "loader_error_classification", paneId: "w1:p2")]
        let results = HerdPaneSearch.rank(panes, query: "catver")

        #expect(results.count == 1)
        #expect(results.first?.pane.agent.tabLabel == "catalog_version_diff")
        #expect(results.first?.matchedField == .tabLabel)
    }

    /// Characters that appear in the wrong order are not a subsequence and must not match, otherwise
    /// the list degrades into "contains these letters somewhere" and stops being useful.
    @Test func outOfOrderCharactersDoNotMatch() {
        let panes = [pane(label: "catalog_version_diff", cwd: "/tmp/a", kind: "x", session: "s")]
        #expect(HerdPaneSearch.rank(panes, query: "vercat").isEmpty)
    }

    /// Matching is case-insensitive, so the user never has to reproduce an identifier's casing.
    @Test func matchingIgnoresCase() {
        let panes = [pane(label: "CatalogVersionDiff")]
        #expect(HerdPaneSearch.rank(panes, query: "cvd").count == 1)
    }

    /// A query longer than every candidate cannot be a subsequence of any of them.
    @Test func queryLongerThanCandidateDoesNotMatch() {
        let panes = [pane(label: "ab", cwd: "/a", kind: "b", session: "c")]
        #expect(HerdPaneSearch.rank(panes, query: "abcdefgh").isEmpty)
    }

    // MARK: - Ranking

    /// Word-initial matches outrank incidental ones. `cvd` spells the three word starts of
    /// `catalog_version_diff`; it also happens to be a subsequence of `code_verify_dispatch`-style
    /// noise, and the intended one has to win.
    @Test func wordStartsOutrankIncidentalMatches() throws {
        let panes = [
            pane(label: "concurrency_valve_dedupe", paneId: "w1:p1"),
            pane(label: "catalog_version_diff", paneId: "w1:p2")
        ]
        let results = HerdPaneSearch.rank(panes, query: "cvd")

        #expect(results.count == 2)
        #expect(results.first?.pane.agent.tabLabel == "catalog_version_diff")
    }

    /// A prefix match beats a match buried in the middle of a longer identifier.
    @Test func prefixOutranksInteriorMatch() throws {
        let panes = [
            pane(label: "rebuild_loader_pipeline", paneId: "w1:p1"),
            pane(label: "loader_error_classification", paneId: "w1:p2")
        ]
        let results = HerdPaneSearch.rank(panes, query: "loader")

        #expect(results.first?.pane.agent.tabLabel == "loader_error_classification")
    }

    /// Field weighting: with two panes whose matches are otherwise identical in shape, the one that
    /// matched on its tab label outranks the one that only matched on its session name.
    @Test func tabLabelOutweighsSessionName() throws {
        let onLabel = pane(label: "hermes", cwd: "/a", kind: "x", session: "alpha", paneId: "w1:p1")
        let onSession = pane(label: "zzzz", cwd: "/b", kind: "y", session: "hermes", paneId: "w1:p2")
        let results = HerdPaneSearch.rank([onSession, onLabel], query: "hermes")

        #expect(results.count == 2)
        #expect(results.first?.matchedField == .tabLabel)
        #expect(results.last?.matchedField == .sessionName)
    }

    /// The weighting is a multiplier, not an override: a strong `cwd` match must be allowed to beat a
    /// weak tab-label match, which is what someone typing a repository name is asking for.
    ///
    /// `keyboard_ring_fix` contains `boring` as a subsequence only incidentally, scattered across two
    /// words and starting mid-word, while `/Users/x/boring` matches it as a whole path component. The
    /// weaker match on the higher-weighted field has to lose.
    @Test func strongCwdMatchBeatsWeakTabLabelMatch() throws {
        let weakLabel = pane(
            label: "keyboard_ring_fix",
            cwd: "/unrelated",
            kind: "x",
            session: "s1",
            paneId: "w1:p1"
        )
        let strongCwd = pane(
            label: "zzzz",
            cwd: "/Users/x/boring",
            kind: "y",
            session: "s2",
            paneId: "w1:p2"
        )
        let results = HerdPaneSearch.rank([weakLabel, strongCwd], query: "boring")

        #expect(results.count == 2)
        #expect(results.first?.matchedField == .cwd)
    }

    /// Equal scores keep the order the snapshot gave, so the list does not reshuffle under the cursor
    /// between two panes that are equally good answers.
    @Test func tiesKeepSnapshotOrder() throws {
        let first = pane(label: "build", cwd: "/a", kind: "k", session: "s", paneId: "w1:p1")
        let second = pane(label: "build", cwd: "/a", kind: "k", session: "s", paneId: "w1:p2")
        let results = HerdPaneSearch.rank([first, second], query: "build")

        #expect(results.map(\.pane.agent.paneId) == ["w1:p1", "w1:p2"])
    }

    // MARK: - Highlighting

    /// Offsets point at the matched characters of the matched field, which is what the result row
    /// tints. Verified by reconstructing the query from them.
    @Test func offsetsIdentifyTheMatchedCharacters() throws {
        let results = HerdPaneSearch.rank([pane(label: "catalog_version_diff")], query: "catver")
        let result = try #require(results.first)
        let text = Array(HerdPaneSearch.text(of: result.matchedField, for: result.pane))

        #expect(result.matchedOffsets.count == 6)
        #expect(result.matchedOffsets == result.matchedOffsets.sorted())
        #expect(String(result.matchedOffsets.map { text[$0] }).lowercased() == "catver")
    }

    /// The tab-label field falls back to the `cwd` basename exactly as the panel row does, so a pane
    /// herdr never labelled is still findable by the name the user can see.
    @Test func unlabelledPaneIsFoundByCwdBasename() throws {
        let panes = [pane(label: nil, cwd: "/Users/x/playground/catalog-svd", kind: "z", session: "s")]
        let results = HerdPaneSearch.rank(panes, query: "svd")

        #expect(results.count == 1)
        #expect(HerdPaneSearch.text(of: .tabLabel, for: try #require(results.first).pane) == "catalog-svd")
    }

    // MARK: - Empty query and limits

    /// An empty query is not a filter: opening the search shows the same panes the panel does, in the
    /// same order, so the window is usable before a single keystroke.
    @Test func emptyQueryReturnsEverythingInOrder() {
        let panes = (1...3).map { pane(label: "tab\($0)", paneId: "w1:p\($0)") }
        let results = HerdPaneSearch.rank(panes, query: "   ")

        #expect(results.map(\.pane.agent.tabLabel) == ["tab1", "tab2", "tab3"])
        #expect(results.allSatisfy { $0.matchedOffsets.isEmpty })
    }

    /// The limit caps the work the view lays out when a one-character query matches everything.
    @Test func limitCapsResults() {
        let panes = (1...20).map { pane(label: "alpha\($0)", paneId: "w1:p\($0)") }
        #expect(HerdPaneSearch.rank(panes, query: "a", limit: 5).count == 5)
    }

    // MARK: - Flattening

    /// Flattening walks the whole tree and keys each pane on session plus pane id, because `paneId`
    /// alone repeats across sessions and a flat list keyed on it would collapse two real panes into
    /// one row.
    @Test func flattenKeysPanesAcrossSessions() throws {
        func session(_ name: String) -> HerdSession {
            var built = HerdSession(name: name, isDefault: false, running: true, socketPath: "/tmp/\(name)")
            built.workspaces = [
                HerdWorkspace(
                    workspaceId: "w1",
                    label: "main",
                    focused: false,
                    agentStatus: .idle,
                    agents: [
                        HerdAgent(
                            agent: "claude",
                            agentStatus: .idle,
                            cwd: "/tmp",
                            paneId: "w1:p1",
                            tabId: "w1:t1",
                            workspaceId: "w1"
                        )
                    ]
                )
            ]
            return built
        }

        let snapshot = HerdSnapshot(sessions: [session("alpha"), session("beta")], counts: StatusCounts())
        let panes = HerdPane.flatten(snapshot)

        #expect(panes.count == 2)
        #expect(Set(panes.map(\.id)).count == 2)
        #expect(panes.map(\.workspaceLabel) == ["main", "main"])
    }

    /// Flattening sorts across every session at once, not within each workspace.
    ///
    /// This is the whole point of the flat sort, and it is what the hierarchical traversal got wrong. The
    /// fixture below is the shape a real herd produced: two workspaces, each internally sorted, whose
    /// traversal interleaves to `working, idle, working, idle`. In the ledger that reads correctly because
    /// the workspace names are printed and the grouping is visible; flattened into the search window the
    /// grouping is gone and only the interleaving is left, which reads as unsorted. A flat surface has to
    /// sort flat.
    @Test func flattenSortsFlatlyByUrgencyAcrossWorkspaces() {
        func agent(_ label: String, _ status: AgentStatus, pane: String) -> HerdAgent {
            HerdAgent(
                agent: "claude",
                agentStatus: status,
                cwd: "/tmp/\(label)",
                paneId: pane,
                tabId: "t\(pane)",
                workspaceId: String(pane.prefix(2)),
                tabLabel: label
            )
        }

        var session = HerdSession(
            name: "default",
            isDefault: true,
            running: true,
            socketPath: "/tmp/default.sock"
        )
        session.workspaces = [
            // Each workspace is already sorted within itself, exactly as HerdSnapshotBuilder leaves it.
            HerdWorkspace(workspaceId: "w1", label: "one", number: 1, agentStatus: .working, agents: [
                agent("w1_working", .working, pane: "w1:p1"),
                agent("w1_idle", .idle, pane: "w1:p2"),
            ]),
            HerdWorkspace(workspaceId: "w2", label: "two", number: 2, agentStatus: .blocked, agents: [
                agent("w2_blocked", .blocked, pane: "w2:p1"),
                agent("w2_done", .done, pane: "w2:p2"),
                agent("w2_idle", .idle, pane: "w2:p3"),
            ]),
        ]

        let panes = HerdPane.flatten(HerdSnapshot(sessions: [session], counts: StatusCounts()))

        #expect(
            panes.map { $0.agent.tabLabel } == [
                "w2_blocked", "w2_done", "w1_working", "w1_idle", "w2_idle",
            ]
        )
    }

    /// The recency set has to reach the flat sort, or a just-finished agent ranks in the search window
    /// where the panel does not rank it, which is the two surfaces disagreeing in a way the user can see.
    @Test func flattenHonoursTheRecencySet() {
        func agent(_ label: String, _ status: AgentStatus, pane: String) -> HerdAgent {
            HerdAgent(
                agent: "claude",
                agentStatus: status,
                cwd: "/tmp/\(label)",
                paneId: pane,
                tabId: "t\(pane)",
                workspaceId: "w1",
                tabLabel: label
            )
        }

        var session = HerdSession(
            name: "s",
            isDefault: true,
            running: true,
            socketPath: "/tmp/s.sock"
        )
        session.workspaces = [
            HerdWorkspace(workspaceId: "w1", label: "one", number: 1, agentStatus: .working, agents: [
                agent("busy", .working, pane: "w1:p1"),
                agent("just_finished", .idle, pane: "w1:p2"),
                agent("quiet", .idle, pane: "w1:p3"),
            ]),
        ]
        let snapshot = HerdSnapshot(sessions: [session], counts: StatusCounts())

        // Without recency, the idle panes stay behind the working one.
        #expect(
            HerdPane.flatten(snapshot).map { $0.agent.tabLabel }
                == ["busy", "just_finished", "quiet"]
        )

        // With it, the remembered pane outranks working, matching the ledger.
        let key = HerdUrgencyOrder.key(sessionName: "s", paneId: "w1:p2")
        #expect(
            HerdPane.flatten(snapshot, recentlyCompleted: [key]).map { $0.agent.tabLabel }
                == ["just_finished", "busy", "quiet"]
        )
    }

    /// An empty query must hand back the flat urgency order untouched, since that is what makes opening
    /// the search window show the same ranking the panel does.
    @Test func anEmptyQueryPreservesTheFlatUrgencyOrder() {
        func agent(_ label: String, _ status: AgentStatus, pane: String) -> HerdAgent {
            HerdAgent(
                agent: "claude",
                agentStatus: status,
                cwd: "/tmp/\(label)",
                paneId: pane,
                tabId: "t\(pane)",
                workspaceId: "w1",
                tabLabel: label
            )
        }

        var session = HerdSession(
            name: "s",
            isDefault: true,
            running: true,
            socketPath: "/tmp/s.sock"
        )
        session.workspaces = [
            HerdWorkspace(workspaceId: "w1", label: "one", number: 1, agentStatus: .blocked, agents: [
                agent("idle_one", .idle, pane: "w1:p1"),
                agent("blocked_one", .blocked, pane: "w1:p2"),
            ]),
        ]

        let panes = HerdPane.flatten(HerdSnapshot(sessions: [session], counts: StatusCounts()))
        let results = HerdPaneSearch.rank(panes, query: "")

        #expect(results.map { $0.pane.agent.tabLabel } == ["blocked_one", "idle_one"])
        #expect(results.allSatisfy { $0.score == 0 })
        #expect(results.allSatisfy { $0.matchedOffsets.isEmpty })
    }
}
