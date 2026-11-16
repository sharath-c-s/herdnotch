import Foundation

/// The JSON Claude Code writes to a PermissionRequest hook's stdin. Unknown keys are ignored.
public struct HookRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let toolName: String
    public let toolInput: JSONValue
    public let permissionSuggestions: [JSONValue]

    public init(
        sessionID: String, toolName: String, toolInput: JSONValue = .object([:]),
        permissionSuggestions: [JSONValue] = []
    ) {
        self.sessionID = sessionID
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        toolName = try c.decode(String.self, forKey: .toolName)
        toolInput = try c.decodeIfPresent(JSONValue.self, forKey: .toolInput) ?? .object([:])
        permissionSuggestions = try c.decodeIfPresent([JSONValue].self, forKey: .permissionSuggestions) ?? []
    }
}

/// What to tell Claude Code for one permission request.
public enum HookDecision: Sendable, Equatable {
    case allow
    /// Allow and persist `permissionSuggestions[suggestionIndex]` as a rule.
    case always(suggestionIndex: Int)
    case deny(message: String)
    /// Answer an AskUserQuestion: question text to chosen option label.
    case answers([String: String])
    /// Say nothing, so Claude falls back to its own terminal dialog.
    case passthrough
}

/// Renders a decision as hook stdout. These shapes were verified against Claude Code; do not add fields.
public enum HookOutput {
    public static func render(_ d: HookDecision, for r: HookRequest) -> Data {
        let decision: String
        switch d {
        case .passthrough:
            return Data()
        case .allow:
            decision = #"{"behavior":"allow"}"#
        case .always(let i):
            if r.permissionSuggestions.indices.contains(i) {
                decision = #"{"behavior":"allow","updatedPermissions":["#
                    + r.permissionSuggestions[i].compactJSON + "]}"
            } else {
                decision = #"{"behavior":"allow"}"#
            }
        case .deny(let message):
            decision = #"{"behavior":"deny","message":"# + JSONValue.string(message).compactJSON + "}"
        case .answers(let map):
            var input: [String: JSONValue] = [:]
            if case .object(let original) = r.toolInput { input = original }
            input["answers"] = .object(map.mapValues { .string($0) })
            decision = #"{"behavior":"allow","updatedInput":"# + JSONValue.object(input).compactJSON + "}"
        }
        let line = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + decision + "}}"
        return Data(line.utf8)
    }
}

/// The `--claude-permission-hook` side: relays hook stdin to the app and the app's reply to stdout.
public enum PermissionHookClient {
    /// Command-line flag that makes the app act as the hook relay. `scripts/install-claude-hook.sh` repeats it.
    public static let flag = "--claude-permission-hook"

    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HerdNotch/approvals.sock").path
    }

    /// Blocks until the app answers; returns its reply line, or empty Data on ANY failure.
    ///
    /// Empty output makes Claude fall back to its own dialog, so a quit or broken app never blocks Claude.
    public static func run(
        stdin: Data, socketPath: String, connector: any SocketConnecting = UnixSocketConnector(),
        timeout: TimeInterval = 590
    ) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: stdin),
            var line = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return Data() }
        line.append(UInt8(ascii: "\n"))

        let deadline = Deadline(after: timeout)
        do {
            let connection = try connector.connect(path: socketPath, timeout: deadline.remaining)
            defer { connection.close() }
            try connection.write(line)
            var framer = NDJSONFramer()
            while deadline.remaining > 0 {
                let chunk = try connection.read(timeout: deadline.remaining)
                if chunk.isEmpty { return Data() }
                if let reply = try framer.append(chunk).first { return reply }
            }
        } catch {}
        return Data()
    }
}
