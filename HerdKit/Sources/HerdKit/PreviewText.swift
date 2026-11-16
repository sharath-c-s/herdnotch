import Foundation

/// Pure text shaping for the notch preview card. Nothing here ever drops characters silently.
public enum PreviewText {
    /// Input is untrusted and rendered from a SwiftUI body: each line is cut to this many characters before wrapping.
    public static let maxLineCharacters = 4000
    /// Lines beyond this are not wrapped; their characters still count as hidden.
    public static let maxInputLines = 400

    /// Hard-wraps `lines` to `columns` characters (preferring spaces) and caps the result at `maxRows`.
    ///
    /// On overflow the head variant ends with a "… N more chars, Jump to see all" row counting the hidden
    /// characters, including any cut by the input caps. `keepTail` instead keeps the last rows and marks
    /// nothing, for live pane output.
    public static func rows(_ lines: [String], columns: Int, maxRows: Int, keepTail: Bool = false) -> [String] {
        let width = max(8, columns)
        let cap = max(1, maxRows)
        let capped = lines.prefix(maxInputLines)
        var uncounted = lines.dropFirst(maxInputLines).reduce(0) { $0 + $1.count }

        if keepTail {
            // Wrap from the end and stop as soon as `cap` rows exist.
            var tail: [String] = []
            for line in capped.reversed() {
                tail += wrap(line.prefix(maxLineCharacters), width: width).reversed()
                if tail.count >= cap { break }
            }
            return Array(tail.prefix(cap).reversed())
        }

        var all: [String] = []
        var skipped = false
        for line in capped {
            // Once `cap` rows exist, later lines are only counted, never wrapped.
            if all.count >= cap {
                skipped = true
                uncounted += line.count
                continue
            }
            let head = line.prefix(maxLineCharacters)
            uncounted += line.count - head.count
            all += wrap(head, width: width)
        }
        guard all.count > cap || uncounted > 0 || skipped else { return all }
        let keep = min(all.count, cap - 1)
        let hidden = all.dropFirst(keep).reduce(uncounted) { $0 + $1.count }
        return Array(all.prefix(keep)) + ["\u{2026} \(hidden) more chars, Jump to see all"]
    }

    /// Linear in the line length: every step advances by index offsets, never by recounting the remainder.
    private static func wrap(_ line: Substring, width: Int) -> [String] {
        var out: [String] = []
        var rest = line
        while let cut = rest.index(rest.startIndex, offsetBy: width, limitedBy: rest.endIndex), cut != rest.endIndex {
            let head = rest[rest.startIndex...cut]
            // Break at the last space in the second half of the window, else hard-cut.
            if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > width / 2 {
                out.append(String(rest[rest.startIndex..<space]))
                rest = rest[rest.index(after: space)...]
            } else {
                out.append(String(rest[rest.startIndex..<cut]))
                rest = rest[cut...]
            }
        }
        out.append(String(rest))
        return out
    }

    /// Display form of a menu label: cut at the first ":" or " · ", then drop a trailing " for".
    public static func shortLabel(_ label: String) -> String {
        var cut = label
        for separator in [":", " \u{00B7} "] {
            if let range = cut.range(of: separator) { cut = String(cut[cut.startIndex..<range.lowerBound]) }
        }
        cut = cut.trimmingCharacters(in: .whitespaces)
        if cut.hasSuffix(" for") { cut = String(cut.dropLast(4)) }
        return cut.isEmpty ? label : cut
    }

    /// Full, untruncated lines for a hook request: known tools via ``ToolSummarizer``, others as `key: value`.
    public static func hookLines(toolName: String, input: [String: Any]) -> [String] {
        let known: Set = ["Bash", "Edit", "MultiEdit", "Write", "AskUserQuestion"]
        if known.contains(toolName) {
            return ToolSummarizer.previewLines(name: toolName, input: input, maxLines: maxInputLines, width: .max)
        }
        let lines: [String] = input.keys.sorted().prefix(maxInputLines).compactMap { key in
            let text: String?
            switch input[key] {
            case let s as String: text = s.split(whereSeparator: \.isNewline).first.map(String.init)
            case let n as NSNumber: text = n.stringValue
            default: text = nil
            }
            return text.map { "\(key): \($0)" }
        }
        return lines.isEmpty ? [ToolSummarizer.displayName(toolName)] : lines
    }

    /// Tooltip for the "Always" button: what choosing `suggestion` would remember.
    public static func alwaysHelp(_ suggestion: JSONValue?) -> String {
        guard case .object(let s)? = suggestion, case .string(let type)? = s["type"] else {
            return "Allow and remember the suggested rule"
        }
        switch type {
        case "addRules":
            guard case .array(let rules)? = s["rules"] else { return type }
            let shown: [String] = rules.compactMap {
                guard case .object(let r) = $0, case .string(let tool)? = r["toolName"] else { return nil }
                if case .string(let content)? = r["ruleContent"], !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            return shown.isEmpty ? type : "Always allow " + shown.joined(separator: ", ")
        case "setMode":
            if case .string(let mode)? = s["mode"] { return "Switch to \(mode) mode" }
            return type
        default:
            return type
        }
    }

    /// Rows a left-to-right wrapping flow of items of the given widths needs inside `available`.
    public static func flowRows(widths: [Double], available: Double, spacing: Double) -> Int {
        guard !widths.isEmpty else { return 0 }
        var rows = 1
        var used = 0.0
        for width in widths {
            if used > 0, used + spacing + width > available {
                rows += 1
                used = width
            } else {
                used += (used > 0 ? spacing : 0) + width
            }
        }
        return rows
    }
}
