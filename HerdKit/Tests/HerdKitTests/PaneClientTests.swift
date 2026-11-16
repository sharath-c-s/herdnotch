import Foundation
import HerdKit
import Testing

struct PaneClientTests {
    private func object(_ data: Data?) throws -> [String: Any] {
        let line = try #require(data).dropLast()
        return try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func readPaneSendsVisibleRequestAndDecodesResult() throws {
        let reply = Data(#"{"id":"x","result":{"pane_id":"p1","workspace_id":"w","tab_id":"t","source":"visible","format":"text","text":"hi\nthere","revision":18446744073709551615,"truncated":false}}"#.utf8 + [10])
        let connector = RecordingConnector(reply: [reply])
        let pane = try HerdrClient(socketPath: "/s", connector: connector).readPane(paneId: "p1", lines: 7)
        #expect(pane == PaneText(text: "hi\nthere", revision: UInt64.max))
        let req = try object(connector.written.first)
        #expect(req["method"] as? String == "pane.read")
        #expect(req["params"] as? NSDictionary == ["pane_id": "p1", "source": "visible", "lines": 7])
    }

    @Test func sendKeysSendsKeyArray() throws {
        let reply = Data((#"{"id":"x","result":{"type":"ok"}}"# + "\n").utf8)
        let connector = RecordingConnector(reply: [reply])
        try HerdrClient(socketPath: "/s", connector: connector).sendKeys(paneId: "p1", keys: ["down", "enter"])
        let req = try object(connector.written.first)
        #expect(req["method"] as? String == "pane.send_keys")
        #expect(req["params"] as? NSDictionary == ["pane_id": "p1", "keys": ["down", "enter"]])
    }

    @Test func sendKeysSurfacesServerError() throws {
        let reply = Data((#"{"id":"","error":{"code":"pane_not_found","message":"no"}}"# + "\n").utf8)
        let client = HerdrClient(socketPath: "/s", connector: RecordingConnector(reply: [reply]))
        #expect(throws: HerdrError.self) { try client.sendKeys(paneId: "p9", keys: ["esc"]) }
    }
}
