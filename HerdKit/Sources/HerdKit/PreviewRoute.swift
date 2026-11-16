import Foundation

/// A single-select AskUserQuestion that the notch can answer with one tap.
public struct QuestionChoice: Sendable, Equatable {
    public let question: String
    public let labels: [String]

    public init(question: String, labels: [String]) {
        self.question = question
        self.labels = labels
    }
}

/// What an expanded agent row offers: answer a hook request, answer a pane menu, or just look.
public enum PreviewRoute: Equatable, Sendable {
    case hook(PendingApproval, canAlways: Bool, question: QuestionChoice?)
    case pane(PanePrompt)
    case previewOnly

    /// Identity of what the card offers; it changes whenever a click aimed at the old buttons could mean something else.
    public var key: String {
        switch self {
        case .hook(let approval, _, _): "h\(approval.token)"
        case .pane(let prompt): "p\(prompt.fingerprint)"
        case .previewOnly: "none"
        }
    }

    /// A pending hook request wins over a pane menu; a pane needs a parsable menu.
    public static func resolve(approval: PendingApproval?, paneText: String?) -> PreviewRoute {
        if let approval {
            return .hook(
                approval, canAlways: !approval.request.permissionSuggestions.isEmpty,
                question: questionChoice(approval.request))
        }
        if let paneText, let prompt = PanePrompt.parse(paneText) { return .pane(prompt) }
        return .previewOnly
    }

    /// Nil unless the request is an AskUserQuestion with exactly one single-select question with options.
    static func questionChoice(_ r: HookRequest) -> QuestionChoice? {
        guard r.toolName == "AskUserQuestion", case .object(let input) = r.toolInput,
            case .array(let questions)? = input["questions"], questions.count == 1,
            case .object(let q) = questions[0], case .string(let text)? = q["question"],
            case .array(let options)? = q["options"]
        else { return nil }
        if case .bool(true)? = q["multiSelect"] { return nil }
        let labels: [String] = options.compactMap {
            if case .object(let o) = $0, case .string(let l)? = o["label"] { return l }
            return nil
        }
        guard !labels.isEmpty, labels.count == options.count else { return nil }
        return QuestionChoice(question: text, labels: labels)
    }
}
