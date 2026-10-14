import Foundation

/// A value that can appear in a herdr request's `params` object.
///
/// herdr's parameters are strings and integers only, so an open `Any` box would buy nothing but
/// runtime failure modes. Extend this enum if and when a method needs another JSON type.
public enum HerdrParam: Encodable, Sendable {
    /// A string parameter, for example a `pane_id`.
    case string(String)
    /// An integer parameter, for example a line count.
    case int(Int)

    /// Encodes as a bare JSON scalar, not a wrapper object.
    ///
    /// - Parameter encoder: Encoder positioned at the parameter's value.
    /// - Throws: Whatever the underlying single-value container throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

/// Performs one request/response exchange against one herdr session socket.
///
/// The protocol is newline-delimited JSON: write one request line, read one response line. This type
/// opens a fresh connection per call and closes it immediately. That costs a connect per call
/// (measured at roughly 36 ms per `agent.list` round trip, well inside a 1 Hz poll budget) and buys
/// the absence of connection state to invalidate when a herdr server restarts underneath the panel.
/// Keep-alive is a later optimisation, not a correctness requirement.
///
/// Thread-safety: a `Sendable` value holding no mutable state. Calls are synchronous and blocking,
/// so callers must not run them on the main thread.
public struct HerdrClient: Sendable {
    /// Absolute path of the session's `herdr.sock`.
    public let socketPath: String

    /// How connections are opened. Injected so tests can replay scripted bytes.
    private let connector: any SocketConnecting

    /// Creates a client for one session socket.
    ///
    /// - Parameters:
    ///   - socketPath: Absolute path of the session's `herdr.sock`.
    ///   - connector: Connection factory. Defaults to real Unix domain sockets.
    public init(socketPath: String, connector: any SocketConnecting = UnixSocketConnector()) {
        self.socketPath = socketPath
        self.connector = connector
    }

    /// Sends one request and returns the raw bytes of its `result` object.
    ///
    /// Raw bytes rather than a decoded value because each method's result has a different shape;
    /// the typed helpers decode them. The response `id` is not matched against the request: only one
    /// request is ever in flight on a connection, and herdr returns an empty `id` on error envelopes,
    /// so there is nothing to match against in the case that would matter.
    ///
    /// - Parameters:
    ///   - method: herdr method name, for example `agent.list`.
    ///   - params: Method parameters. Keys are sent as written, so pass herdr's own snake_case names.
    ///   - timeout: Budget for connect, send and the complete response line.
    /// - Returns: JSON bytes of the response's `result` object.
    /// - Throws: ``HerdrError/server(code:message:)`` when herdr returns an error envelope,
    ///   ``HerdrError/timeout`` when no complete line arrives in time,
    ///   ``HerdrError/protocolError(_:)`` when the peer closes mid-message or the envelope has
    ///   neither `result` nor `error`, ``HerdrError/socketUnavailable(_:)`` when the session is not
    ///   running, ``HerdrError/decode(_:)`` when the response is not a JSON object.
    public func call(
        _ method: String,
        params: [String: HerdrParam] = [:],
        timeout: TimeInterval = 2.0
    ) throws -> Data {
        // One monotonic budget for the whole exchange, started before the first syscall. Each phase
        // gets only what is left, so `timeout` is a real upper bound on the call. Previously connect
        // received the full timeout and the read loop then started a fresh one, which let a nominal
        // 2 s call run past 4 s: with two calls per session per poll, that is enough to stall the
        // 1 Hz poll loop behind a single wedged server.
        let deadline = Deadline(after: timeout)
        let line = try requestLine(method: method, params: params)

        let connection = try connector.connect(path: socketPath, timeout: deadline.remaining)
        defer { connection.close() }
        guard !deadline.hasExpired else { throw HerdrError.timeout }
        try connection.write(line)

        var framer = NDJSONFramer()
        while true {
            let remaining = deadline.remaining
            guard remaining > 0 else { throw HerdrError.timeout }
            let chunk = try connection.read(timeout: remaining)
            guard !chunk.isEmpty else {
                throw HerdrError.protocolError("connection closed before a complete response line")
            }
            if let response = try framer.append(chunk).first {
                return try Self.result(from: response)
            }
        }
    }

    /// Lists every agent in the session.
    ///
    /// - Parameter timeout: Budget for the whole exchange.
    /// - Returns: Agents in herdr's own order, unsorted. ``HerdSnapshotBuilder`` applies display
    ///   ordering.
    /// - Throws: Any ``HerdrError`` from ``call(_:params:timeout:)``, or ``HerdrError/decode(_:)`` if
    ///   the `agent_list` payload does not match ``HerdAgent``.
    public func listAgents(timeout: TimeInterval = 2.0) throws -> [HerdAgent] {
        let data = try call("agent.list", timeout: timeout)
        return try Self.decode(AgentListResult.self, from: data).agents
    }

    /// Lists every workspace in the session, with herdr's own rolled-up status per workspace.
    ///
    /// - Parameter timeout: Budget for the whole exchange.
    /// - Returns: Workspaces with empty `agents`; the caller attaches agents.
    /// - Throws: Any ``HerdrError`` from ``call(_:params:timeout:)``, or ``HerdrError/decode(_:)`` if
    ///   the `workspace_list` payload does not match ``HerdWorkspace``.
    public func listWorkspaces(timeout: TimeInterval = 2.0) throws -> [HerdWorkspace] {
        let data = try call("workspace.list", timeout: timeout)
        return try Self.decode(WorkspaceListResult.self, from: data).workspaces
    }

    /// Fetches the user-visible label of every tab in the session, keyed by `tab_id`.
    ///
    /// Returns a lookup table rather than tab objects because the label is the only field any caller
    /// needs: ``HerdSnapshotBuilder`` joins it onto each agent via ``HerdAgent/tabId`` so a row can
    /// show `catalog_version_diff` instead of the working directory's basename `catalog-svd`.
    ///
    /// Tabs with no label are omitted, so a lookup miss and an empty label are the same thing to the
    /// caller: no label to show.
    ///
    /// - Parameter timeout: Budget for the whole exchange.
    /// - Returns: `tab_id` to label. Empty when the session has no labelled tabs.
    /// - Throws: Any ``HerdrError`` from ``call(_:params:timeout:)``, or ``HerdrError/decode(_:)`` if
    ///   the `tab_list` payload does not match.
    public func listTabLabels(timeout: TimeInterval = 2.0) throws -> [String: String] {
        let data = try call("tab.list", timeout: timeout)
        let tabs = try Self.decode(TabListResult.self, from: data).tabs
        return tabs.reduce(into: [:]) { table, tab in
            guard let label = tab.label, !label.isEmpty else { return }
            table[tab.tabId] = label
        }
    }

    // MARK: - Wire encoding and decoding

    /// A herdr request envelope.
    private struct Request: Encodable {
        let id: String
        let method: String
        let params: [String: HerdrParam]
    }

    /// The `agents` array inside an `agent_list` result.
    private struct AgentListResult: Decodable {
        let agents: [HerdAgent]
    }

    /// The `workspaces` array inside a `workspace_list` result.
    private struct WorkspaceListResult: Decodable {
        let workspaces: [HerdWorkspace]
    }

    /// The `tabs` array inside a `tab_list` result.
    ///
    /// Deliberately not a public model: only the label is consumed, and a public `HerdTab` would be
    /// API surface with no reader. The other fields herdr sends (`number`, `pane_count`,
    /// `agent_status`, `focused`) are simply not decoded.
    private struct TabListResult: Decodable {
        struct Tab: Decodable {
            let tabId: String
            let label: String?
        }
        let tabs: [Tab]
    }

    /// Serialises a request and appends the newline that terminates it on the wire.
    ///
    /// - Throws: ``HerdrError/decode(_:)`` if the parameters cannot be encoded, which can only
    ///   happen through a programming error.
    private func requestLine(method: String, params: [String: HerdrParam]) throws -> Data {
        do {
            var data = try HerdJSON.encoder.encode(
                Request(id: "req_\(UUID().uuidString)", method: method, params: params)
            )
            data.append(UInt8(ascii: "\n"))
            return data
        } catch {
            throw HerdrError.decode("could not encode request \(method): \(error)")
        }
    }

    /// Splits a response line into its `result` payload or throws its `error`.
    ///
    /// Uses `JSONSerialization` rather than `Codable` because the `result` shape is per-method: the
    /// point here is to hand the untouched sub-object to a method-specific decoder.
    ///
    /// - Parameter line: One complete response line, newline already stripped.
    /// - Returns: JSON bytes of the `result` object.
    /// - Throws: ``HerdrError/server(code:message:)`` for an error envelope,
    ///   ``HerdrError/decode(_:)`` if the line is not a JSON object, ``HerdrError/protocolError(_:)``
    ///   if the object carries neither `result` nor a well-formed `error`.
    private static func result(from line: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HerdrError.decode("response was not a JSON object")
        }
        if let failure = object["error"] as? [String: Any] {
            throw HerdrError.server(
                code: failure["code"] as? String ?? "unknown",
                message: failure["message"] as? String ?? ""
            )
        }
        guard let payload = object["result"] else {
            throw HerdrError.protocolError("response had neither result nor error")
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw HerdrError.decode("could not re-serialise result: \(error)")
        }
    }

    /// Decodes a method-specific result payload, converting any failure into ``HerdrError/decode(_:)``
    /// so callers only ever have to handle one error type.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try HerdJSON.decoder.decode(type, from: data)
        } catch {
            throw HerdrError.decode("\(type): \(error)")
        }
    }
}
