import Foundation
import HerdKit
import Testing

struct JSONValueTests {
    @Test func roundTripsAllCases() throws {
        let json = #"{"a":[1,2.5,true,null,"s"],"b":{"c":"d"}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(v == .object([
            "a": .array([.number(1), .number(2.5), .bool(true), .null, .string("s")]),
            "b": .object(["c": .string("d")]),
        ]))
        #expect(v.compactJSON == json)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v)) == v)
    }

    @Test func compactJSONIsSingleLineAndKeepsSlashes() {
        let v = JSONValue.string("a/b\nc\"d")
        #expect(v.compactJSON == #""a/b\nc\"d""#)
    }

    @Test func asAnyConvertsForSummarizer() {
        let v = JSONValue.object(["command": .string("ls"), "n": .number(3)])
        let any = v.asAny as? [String: Any]
        #expect(any?["command"] as? String == "ls")
        #expect(any?["n"] as? Double == 3)
    }
}
