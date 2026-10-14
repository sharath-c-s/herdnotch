import Foundation

/// One agent pane, lifted out of the session → workspace → agent tree into a flat, searchable record.
///
/// Search is the one surface that must ignore the tree: with sixteen agents across four sessions, the
/// user typing `catver` does not know or care which session the pane lives in, and asking them to
/// expand the right branch first would defeat the point. So the tree is flattened once per query.
///
/// The owning ``session`` is carried whole rather than by name because acting on a pane needs its
/// socket path, and a `paneId` such as `w1:p1` is unique only inside its own session. Resolving the
/// session afterwards by searching a snapshot for a matching `paneId` would silently target the wrong
/// pane as soon as two sessions both have a `w1`. Carrying the value costs nothing: `HerdSession` is a
/// struct whose only large member is a copy-on-write array.
///
/// Thread-safety: an immutable `Sendable` value.
public struct HerdPane: Sendable, Identifiable, Hashable {
    /// The session the pane lives in. Supplies `socketPath` for the focus calls.
    public let session: HerdSession

    /// Display name of the containing workspace, shown as context in a result row.
    ///
    /// Denormalised to a `String` rather than holding the whole ``HerdWorkspace`` because the label is
    /// the only part search needs, and a workspace carries its own agent array.
    public let workspaceLabel: String

    /// The agent itself.
    public let agent: HerdAgent

    /// Identity across the whole snapshot, not just within one session.
    ///
    /// ``HerdAgent/id`` is the `paneId`, which is session-scoped, so a flat list keyed on it would
    /// collide the moment two sessions each have a `w1:p1`. Every flat surface has to key on the pair,
    /// which is the same rule the blocked notifier already follows.
    public var id: String { "\(session.name)\u{1}\(agent.paneId)" }

    /// Creates a flattened pane record.
    ///
    /// - Parameters:
    ///   - session: The owning session.
    ///   - workspaceLabel: Display name of the containing workspace.
    ///   - agent: The agent.
    public init(session: HerdSession, workspaceLabel: String, agent: HerdAgent) {
        self.session = session
        self.workspaceLabel = workspaceLabel
        self.agent = agent
    }

    /// Flattens a snapshot into every pane it contains, in **flat** urgency order.
    ///
    /// This used to preserve the snapshot's own order, on the reasoning that the builder had already
    /// decided display order and a second opinion here would let the search results and the panel
    /// disagree. That reasoning was wrong, and the way it was wrong is worth recording, because it looks
    /// right until you see the two surfaces side by side.
    ///
    /// The panel's sort is **hierarchical**: agents are ranked inside their workspace, workspaces inside
    /// their session, and a group is ranked by its most urgent member. That is deliberate and correct
    /// there, because the ledger prints the session and workspace only when they change, so grouping is
    /// visible as whitespace and the reader can see why a working row sits below an idle one. Preserving
    /// that traversal into a flat list keeps the sequence and throws away the grouping that explained it,
    /// so a real six-pane herd came out `working, idle, working, working, idle, idle` and read as simply
    /// unsorted.
    ///
    /// So a flat surface gets a flat sort. Same ranks, same recency input, same stability rule as
    /// ``HerdUrgencyOrder``, applied across every session at once: blocked, then done, then recently
    /// completed, then working, then unknown, then idle. The two surfaces now agree about what "sorted"
    /// means rather than agreeing on a byte sequence.
    ///
    /// - Parameters:
    ///   - snapshot: The tree to flatten.
    ///   - recentlyCompleted: Keys, from ``HerdUrgencyOrder/key(sessionName:paneId:)``, of agents that
    ///     finished inside the caller's recency window. Empty orders by status alone, which is the right
    ///     default for a caller that has no clock rather than a reason to ignore recency.
    /// - Returns: Every agent in every workspace of every session, most urgent first, including stopped
    ///   sessions. Stopped sessions are kept because a pane the user remembers is still worth finding, and
    ///   the result row can say the session is not running; filtering them out here would look like the
    ///   pane vanished.
    public static func flatten(
        _ snapshot: HerdSnapshot,
        recentlyCompleted: Set<String> = []
    ) -> [HerdPane] {
        let panes = snapshot.sessions.flatMap { session in
            session.workspaces.flatMap { workspace in
                workspace.agents.map {
                    HerdPane(
                        session: session,
                        workspaceLabel: workspace.label ?? workspace.workspaceId,
                        agent: $0
                    )
                }
            }
        }

        // Decorated with the original index so the sort is stable. `Array.sorted(by:)` gives no stability
        // guarantee in Swift, and this list is rebuilt every time the window opens, so two panes of equal
        // rank swapping places would move a result out from under the user's selection between one press of
        // the shortcut and the next.
        //
        // Built with a loop and a named struct rather than `enumerated().map` into a tuple, for the same
        // reason `HerdUrgencyOrder.Ranked` exists: the tuple version of this exceeded the Swift type
        // checker's budget and failed to compile with "unable to type-check this expression in reasonable
        // time". Naming the shape fixes it and reads better anyway.
        var ranked: [RankedPane] = []
        ranked.reserveCapacity(panes.count)
        for (index, pane) in panes.enumerated() {
            let urgency = HerdUrgencyOrder.urgency(
                of: pane.agent,
                sessionName: pane.session.name,
                recentlyCompleted: recentlyCompleted
            )
            ranked.append(RankedPane(rank: urgency.rawValue, index: index, pane: pane))
        }
        ranked.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
        }
        return ranked.map(\.pane)
    }

    /// One pane decorated with its urgency rank and its position in the tree walk.
    ///
    /// A named type rather than a tuple, and not for style: see the note in
    /// ``flatten(_:recentlyCompleted:)``.
    private struct RankedPane {
        /// Urgency rank, lower is more urgent.
        let rank: Int
        /// Position in the unsorted tree walk, used as the tie-break that makes the sort stable.
        let index: Int
        /// The pane itself.
        let pane: HerdPane
    }
}

/// Which of a pane's texts a query matched.
///
/// Reported alongside the score so the result row can highlight the text that actually earned the
/// match. Without it a row matched on its `cwd` would show an unhighlighted tab label and look like it
/// had been returned for no reason, which is the fastest way to make a fuzzy list feel broken.
public enum HerdPaneField: String, Sendable, CaseIterable {
    /// The tab label, or the `cwd` basename when herdr has no label. What the user named the work.
    case tabLabel
    /// The full working directory path.
    case cwd
    /// The agent program, for example `claude` or `codex`.
    case agentKind
    /// The owning session's name.
    case sessionName
}

/// One pane that matched a query, with everything the result row needs to render itself.
///
/// Thread-safety: an immutable `Sendable` value.
public struct HerdPaneSearchResult: Sendable, Identifiable {
    /// The matched pane.
    public let pane: HerdPane

    /// Ranking score. Higher is a better match. Comparable only within one query's results, since the
    /// scale depends on the query's length.
    public let score: Int

    /// The field that produced ``score``.
    public let matchedField: HerdPaneField

    /// Character offsets **into ``matchedField``'s text** that the query matched, ascending.
    ///
    /// Offsets rather than `Range<String.Index>` because the consumer is a view that rebuilds the
    /// string character by character to tint the matched ones, and string indices from one `String`
    /// cannot be used to subscript another. Empty for an empty query.
    public let matchedOffsets: [Int]

    /// Identity across sessions, delegated to the pane.
    public var id: String { pane.id }

    /// Creates a result.
    ///
    /// - Parameters:
    ///   - pane: The matched pane.
    ///   - score: Ranking score.
    ///   - matchedField: The field that scored best.
    ///   - matchedOffsets: Matched character offsets into that field's text.
    public init(pane: HerdPane, score: Int, matchedField: HerdPaneField, matchedOffsets: [Int]) {
        self.pane = pane
        self.score = score
        self.matchedField = matchedField
        self.matchedOffsets = matchedOffsets
    }
}

/// Ranks panes against a typed query.
///
/// Subsequence matching rather than substring, because the content is snake_case identifiers and the
/// user types the initials of the words: `catver` has to find `catalog_version_diff`, and no substring
/// search ever will. The scorer is a small deterministic pass rather than a general edit-distance,
/// since the candidate strings are short and the ranking only has to be defensible, not optimal.
///
/// Thread-safety: pure functions over value types, safe to call from anywhere. Cheap enough to run on
/// the main actor per keystroke: sixteen panes times four fields is sixty-four scans of strings around
/// thirty characters long.
public enum HerdPaneSearch {
    /// Relative importance of each field, as a percentage applied to that field's raw score.
    ///
    /// The order is the one the panel already teaches: the tab label is what the user named the work,
    /// the `cwd` is where it lives, the agent kind and the session are context. Multiplying rather than
    /// adding an offset is deliberate. An additive bonus would let a barely-there tab-label match
    /// outrank a perfect `cwd` match forever; a multiplier lets a strong lower-weight match win, which
    /// is what someone typing a repository name expects.
    private static func weight(_ field: HerdPaneField) -> Int {
        switch field {
        case .tabLabel: 100
        case .cwd: 70
        case .agentKind: 50
        case .sessionName: 40
        }
    }

    /// Scores every pane against `query` and returns the ones that matched, best first.
    ///
    /// - Parameters:
    ///   - panes: Candidates, normally from ``HerdPane/flatten(_:)``.
    ///   - query: What the user has typed. Whitespace is trimmed; an empty query is not a filter.
    ///   - limit: Maximum results to return. Caps the work the view has to lay out when the query is
    ///     one character and everything matches.
    /// - Returns: For an empty query, the first `limit` panes in the order they arrived, each with a zero
    ///   score and no highlights, so opening the search shows the most urgent panes first exactly as the
    ///   panel does (see ``HerdPane/flatten(_:recentlyCompleted:)``, which is what establishes that order).
    ///   Otherwise the matching panes sorted by descending score, ties broken by input order, so two
    ///   equally good candidates are separated by urgency rather than reshuffling.
    public static func rank(
        _ panes: [HerdPane],
        query: String,
        limit: Int = 40
    ) -> [HerdPaneSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return panes.prefix(limit).map {
                HerdPaneSearchResult(pane: $0, score: 0, matchedField: .tabLabel, matchedOffsets: [])
            }
        }

        let needle = Array(trimmed.lowercased())
        var scored: [(result: HerdPaneSearchResult, order: Int)] = []
        scored.reserveCapacity(panes.count)

        for (order, pane) in panes.enumerated() {
            guard let best = bestField(for: pane, needle: needle) else { continue }
            scored.append((best, order))
        }

        // Sorting on the tuple keeps the comparison total and therefore the sort stable in effect,
        // without relying on `sorted(by:)` being a stable sort, which Swift does not promise.
        scored.sort { lhs, rhs in
            lhs.result.score == rhs.result.score
                ? lhs.order < rhs.order
                : lhs.result.score > rhs.result.score
        }
        return scored.prefix(limit).map(\.result)
    }

    /// Scores one pane against every field and keeps the best.
    ///
    /// - Parameters:
    ///   - pane: The candidate.
    ///   - needle: The lowercased query, already split into characters.
    /// - Returns: The best-scoring field's result, or `nil` when the query is not a subsequence of any
    ///   field.
    private static func bestField(for pane: HerdPane, needle: [Character]) -> HerdPaneSearchResult? {
        var best: HerdPaneSearchResult?
        for field in HerdPaneField.allCases {
            guard let match = FuzzyMatcher.match(needle: needle, in: text(of: field, for: pane))
            else { continue }
            let weighted = match.score * weight(field) / 100
            if weighted > (best?.score ?? Int.min) {
                best = HerdPaneSearchResult(
                    pane: pane,
                    score: weighted,
                    matchedField: field,
                    matchedOffsets: match.offsets
                )
            }
        }
        return best
    }

    /// The text a field contributes to the search.
    ///
    /// - Parameters:
    ///   - field: Which text to return.
    ///   - pane: The pane to read it from.
    /// - Returns: The field's searchable text. For ``HerdPaneField/tabLabel`` this falls back to the
    ///   `cwd` basename when herdr reported no label, which is the same fallback the panel row uses, so
    ///   what the user sees is always what they can search for.
    public static func text(of field: HerdPaneField, for pane: HerdPane) -> String {
        switch field {
        case .tabLabel:
            if let label = pane.agent.tabLabel, !label.isEmpty { return label }
            return basename(of: pane.agent.cwd)
        case .cwd: return pane.agent.cwd
        case .agentKind: return pane.agent.agent
        case .sessionName: return pane.session.name
        }
    }

    /// Last path component of a directory path, with any trailing slash ignored.
    ///
    /// - Parameter path: An absolute or relative path.
    /// - Returns: The final component, or `/` for the root.
    private static func basename(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.isEmpty ? "/" : (trimmed.split(separator: "/").last.map(String.init) ?? trimmed)
    }
}

/// Subsequence scorer for short identifiers.
///
/// A single greedy left-to-right pass rather than the full dynamic-programming optimum. The candidates
/// here are one-line identifiers and paths, so the greedy match and the optimal match differ only in
/// contrived cases, and the greedy pass is O(candidate) with no allocation beyond the offsets it
/// returns. What actually decides ranking quality is the bonus structure below, not the search
/// strategy.
///
/// Thread-safety: pure static functions.
enum FuzzyMatcher {
    /// Characters treated as word separators, so a match just after one is a word start.
    ///
    /// `_`, `-` and `/` are the three that matter for this content: snake_case identifiers, kebab-case
    /// directory names, and path segments. Someone typing `catver` for `catalog_version_diff` is
    /// spelling out word starts, so recognising them is what makes the ranking match the intent.
    private static let separators: Set<Character> = ["_", "-", "/", ".", " ", ":"]

    /// Awarded when the first query character lands on the candidate's first character.
    private static let prefixBonus = 20
    /// Awarded when a character matches at the start of a word.
    private static let wordStartBonus = 12
    /// Awarded when a character matches immediately after the previous match.
    private static let adjacencyBonus = 10
    /// Awarded per character for matching the candidate's own case, which breaks ties between an
    /// exact-case and a case-folded hit without ever rejecting the latter.
    private static let exactCaseBonus = 2
    /// Charged per candidate character skipped between two matches, capped by ``maximumGapPenalty``.
    private static let gapPenalty = 1
    /// Ceiling on the penalty for one gap, so a single long path segment cannot bury an otherwise good
    /// match under an unbounded negative.
    private static let maximumGapPenalty = 12

    /// Greedily matches `needle` as a subsequence of `candidate` and scores the result.
    ///
    /// - Parameters:
    ///   - needle: The lowercased query characters. Must not be empty; an empty needle is the caller's
    ///     "no filter" case and never reaches here.
    ///   - candidate: The text to search. Matched case-insensitively.
    /// - Returns: The score and the matched character offsets, or `nil` when `needle` is not a
    ///   subsequence of `candidate`.
    static func match(needle: [Character], in candidate: String) -> (score: Int, offsets: [Int])? {
        guard !needle.isEmpty else { return nil }
        let haystack = Array(candidate)
        guard haystack.count >= needle.count else { return nil }

        var offsets: [Int] = []
        offsets.reserveCapacity(needle.count)
        var score = 0
        var position = 0

        for (needleIndex, wanted) in needle.enumerated() {
            var found: Int?
            var index = position
            while index < haystack.count {
                if Character(haystack[index].lowercased()) == wanted {
                    found = index
                    break
                }
                index += 1
            }
            guard let matchIndex = found else { return nil }

            let gap = matchIndex - position
            if needleIndex == 0 {
                if matchIndex == 0 { score += prefixBonus }
            } else if gap == 0 {
                score += adjacencyBonus
            }
            if gap > 0 {
                score -= min(gap * gapPenalty, maximumGapPenalty)
            }
            if isWordStart(haystack, at: matchIndex) { score += wordStartBonus }
            if haystack[matchIndex] == wanted { score += exactCaseBonus }

            offsets.append(matchIndex)
            position = matchIndex + 1
        }

        // A short candidate that the query nearly fills is a better answer than a long one that merely
        // contains the same letters, so the leftover length is charged for. Integer-divided so it only
        // separates candidates that differ by several characters, never two near-equal ones.
        score -= (haystack.count - needle.count) / 4
        return (score, offsets)
    }

    /// Whether the character at `index` begins a word.
    ///
    /// True at the very start, just after a separator, and at a lower-to-upper camelCase boundary. The
    /// camelCase case is included because herdr tab labels are user-typed and not reliably snake_case.
    ///
    /// - Parameters:
    ///   - characters: The candidate, already split.
    ///   - index: Position to test. Must be in bounds.
    /// - Returns: `true` when the position is a word start.
    private static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if separators.contains(previous) { return true }
        return previous.isLowercase && characters[index].isUppercase
    }
}
