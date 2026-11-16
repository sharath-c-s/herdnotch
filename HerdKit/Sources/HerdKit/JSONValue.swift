import Foundation

/// A JSON document node, used to carry hook payloads (`tool_input`, permission suggestions) verbatim.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Single-line JSON with object keys sorted. Never contains a raw newline (strings escape it).
    public var compactJSON: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let v):
            guard v.isFinite else { return "null" }
            return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : "\(v)"
        case .string(let v): return Self.quote(v)
        case .array(let v): return "[" + v.map(\.compactJSON).joined(separator: ",") + "]"
        case .object(let v):
            return "{" + v.keys.sorted().map { Self.quote($0) + ":" + v[$0]!.compactJSON }.joined(separator: ",") + "}"
        }
    }

    /// Foundation-style value (`NSNull`, `Bool`, `Double`, `String`, `[Any]`, `[String: Any]`).
    public var asAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.asAny)
        case .object(let v): return v.mapValues(\.asAny)
        }
    }

    private static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(s) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
