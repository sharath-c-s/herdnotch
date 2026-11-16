import Foundation

/// A Claude Code choice menu parsed from a pane's visible text.
public struct PanePrompt: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        /// The menu's own number, nil for unnumbered menus (answered with arrow keys).
        public let number: Int?

        public init(label: String, number: Int?) {
            self.label = label
            self.number = number
        }
    }

    /// Up to three lines of context above the menu, top to bottom.
    public let question: [String]
    public let options: [Option]
    public let selectedIndex: Int
    /// Stable across re-reads of the same prompt (selection moves do not change it), so callers can detect a new one.
    public let fingerprint: String

    /// `fingerprint` defaults to the question plus option labels; ``parse(_:)`` passes a wider one.
    public init(question: [String], options: [Option], selectedIndex: Int, fingerprint: String? = nil) {
        self.question = question
        self.options = options
        self.selectedIndex = selectedIndex
        self.fingerprint = fingerprint ?? (question + options.map(\.label)).joined(separator: "\n")
    }

    /// Keys that cancel the prompt.
    public static let denyKeys = ["esc"]

    /// Keys that choose `shown.options[optionIndex]` on the pane as it reads now, or nil when `fresh` is no longer
    /// the prompt that was shown (does not parse, or fingerprint differs). Empty when the index is out of range.
    public static func answerKeys(fresh: String, shown: PanePrompt, optionIndex: Int) -> [String]? {
        guard let prompt = parse(fresh), prompt.fingerprint == shown.fingerprint else { return nil }
        return prompt.keys(for: optionIndex)
    }

    /// ``denyKeys`` when `fresh` still shows the prompt that was shown, else nil.
    public static func cancelKeys(fresh: String, shown: PanePrompt) -> [String]? {
        guard let prompt = parse(fresh), prompt.fingerprint == shown.fingerprint else { return nil }
        return denyKeys
    }

    private static let markers: Set<Character> = ["\u{276F}", "\u{203A}", ">"]
    private static let freeTextPrefixes = ["Type something", "Chat about this"]

    /// Keys that choose `options[optionIndex]`; empty when the index is out of range.
    public func keys(for optionIndex: Int) -> [String] {
        guard options.indices.contains(optionIndex) else { return [] }
        if let number = options[optionIndex].number { return ["\(number)"] }
        let delta = optionIndex - selectedIndex
        return Array(repeating: delta >= 0 ? "down" : "up", count: abs(delta)) + ["enter"]
    }

    /// Parses the last menu (at least two options) in `text`, or nil when there is none, e.g. an idle prompt.
    public static func parse(_ text: String) -> PanePrompt? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rows = lines.map(Row.init)
        // Numbered first: on a tie in end position the earlier-added candidate wins.
        let candidates = numberedBlocks(rows) + unnumberedBlocks(rows)
        var best: Block?
        for c in candidates where best == nil || c.end > best!.end { best = c }
        guard let block = best else { return nil }

        let kept = block.options.enumerated().filter { _, o in
            !freeTextPrefixes.contains { o.label.hasPrefix($0) }
        }
        guard kept.count >= 2 else { return nil }
        let selected = kept.firstIndex { $0.offset == block.selected } ?? 0
        // Everything above the options counts, so two commands sharing a last line still differ.
        let above = lines[..<block.start].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isSeparator($0) && !$0.hasPrefix("Tip:") }
        return PanePrompt(
            question: questionLines(above: block.start, in: lines),
            options: kept.map(\.element),
            selectedIndex: selected,
            fingerprint: (above + kept.map(\.element.label)).joined(separator: "\n")
        )
    }

    // MARK: - Parsing

    private struct Block {
        var options: [Option] = []
        var selected = 0
        var start = 0
        var end = 0
    }

    private struct Row {
        let indent: Int
        let isBlank: Bool
        let hasMarker: Bool
        let number: Int?
        let numberColumn: Int
        let dotColumn: Int
        /// Text of the option, or of the whole line when it is not numbered.
        let label: String
        /// Column where `label` starts.
        let labelColumn: Int

        init(_ line: String) {
            let chars = Array(line)
            var i = 0
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            indent = i
            isBlank = i == chars.count
            var hasMarker = false
            if i < chars.count, PanePrompt.markers.contains(chars[i]) {
                hasMarker = true
                i += 1
                while i < chars.count, chars[i] == " " { i += 1 }
            }
            self.hasMarker = hasMarker
            let digitsStart = i
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            if i > digitsStart, i + 1 < chars.count, chars[i] == ".", chars[i + 1] == " " {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                let label = String(chars[j...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    number = Int(String(chars[digitsStart..<i]))
                    numberColumn = digitsStart
                    dotColumn = i
                    self.label = label
                    labelColumn = j
                    return
                }
            }
            number = nil
            numberColumn = -1
            dotColumn = -1
            labelColumn = hasMarker ? i : indent
            label = String(chars[min(labelColumn, chars.count)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func numberedBlocks(_ rows: [Row]) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var anchor: Row?
        func flush() {
            if let c = current, c.options.count >= 2 { blocks.append(c) }
            current = nil
            anchor = nil
        }
        for (i, row) in rows.enumerated() {
            if let number = row.number {
                if let a = anchor, row.numberColumn == a.numberColumn || row.dotColumn == a.dotColumn {
                    let index = current?.options.count ?? 0
                    if row.hasMarker { current?.selected = index }
                    current?.options.append(Option(label: row.label, number: number))
                    current?.end = i
                    continue
                }
                flush()
                anchor = row
                current = Block(
                    options: [Option(label: row.label, number: number)],
                    selected: 0, start: i, end: i)
            } else if let a = anchor, row.isBlank || row.indent > a.numberColumn {
                continue
            } else {
                flush()
            }
        }
        flush()
        return blocks
    }

    private static func unnumberedBlocks(_ rows: [Row]) -> [Block] {
        var blocks: [Block] = []
        for (i, row) in rows.enumerated() where row.hasMarker && row.number == nil && !row.label.isEmpty {
            let col = row.labelColumn
            func sibling(_ r: Row) -> Bool { !r.isBlank && r.number == nil && r.indent == col && !r.hasMarker }
            func continuation(_ r: Row) -> Bool { !r.isBlank && r.indent > col }
            var start = i
            var j = i - 1
            while j >= 0, sibling(rows[j]) || continuation(rows[j]) {
                if sibling(rows[j]) { start = j }
                j -= 1
            }
            var end = i
            j = i + 1
            while j < rows.count, sibling(rows[j]) || continuation(rows[j]) {
                if sibling(rows[j]) { end = j }
                j += 1
            }
            var block = Block(start: start, end: end)
            for k in start...end where k == i || sibling(rows[k]) {
                if k == i { block.selected = block.options.count }
                block.options.append(Option(label: rows[k].label, number: nil))
            }
            if block.options.count >= 2 { blocks.append(block) }
        }
        return blocks
    }

    private static func questionLines(above start: Int, in lines: [String]) -> [String] {
        var found: [String] = []
        var i = start - 1
        while i >= 0, found.count < 3 {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            i -= 1
            if line.isEmpty || line.hasPrefix("Tip:") { continue }
            if isSeparator(line) { continue }
            found.append(line)
        }
        return found.reversed()
    }

    private static func isSeparator(_ line: String) -> Bool {
        line.allSatisfy { $0 == "\u{2500}" || $0 == "\u{254C}" }
    }
}
