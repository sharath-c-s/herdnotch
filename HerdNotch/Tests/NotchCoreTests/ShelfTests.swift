import Foundation
import Testing

@testable import NotchCore

@Suite struct ShelfTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        id: UUID = UUID(), age: TimeInterval = 0, source: String = "/tmp/a.txt", modified: TimeInterval = 5
    ) -> ShelfItem {
        ShelfItem(
            id: id, fileName: "a.txt", relativePath: Shelf.cacheRelativePath(id: id, fileName: "a.txt"),
            addedAt: now.addingTimeInterval(-age), byteSize: 10, sourcePath: source,
            sourceModified: Date(timeIntervalSince1970: modified))
    }

    @Test func expiredReturnsItemsAtOrPastTTL() {
        let fresh = item(age: 24 * 3600 - 1)
        let edge = item(age: 24 * 3600)
        let old = item(age: 48 * 3600)
        let result = Shelf.expired([fresh, edge, old], now: now)
        #expect(result.map(\.id) == [edge.id, old.id])
    }

    @Test func expiredHonoursCustomTTL() {
        let a = item(age: 100)
        #expect(Shelf.expired([a], now: now, ttl: 50) == [a])
        #expect(Shelf.expired([a], now: now, ttl: 200).isEmpty)
    }

    @Test func cacheRelativePathKeepsOriginalNameUnderUUIDFolder() {
        let id = UUID()
        #expect(Shelf.cacheRelativePath(id: id, fileName: "report final.pdf") == "\(id.uuidString)/report final.pdf")
    }

    @Test func sameSourceAndModificationDateReplacesOldItem() {
        let old = item()
        let new = item()
        let result = Shelf.inserting(new, into: [old])
        #expect(result.items == [new])
        #expect(result.replaced == [old])
    }

    @Test func changedModificationDateOrSourceKeepsBoth() {
        let old = item()
        let edited = item(modified: 6)
        let other = item(source: "/tmp/b.txt")
        #expect(Shelf.inserting(edited, into: [old]).items == [old, edited])
        #expect(Shelf.inserting(other, into: [old]).replaced.isEmpty)
    }

    @Test func dropSizeCapAcceptsExactlyCapAndRejectsOver() {
        let cap = Shelf.maxDropBytes
        #expect(cap == 500_000_000)
        #expect(Shelf.isDropAllowed(sizes: [cap]))
        #expect(Shelf.isDropAllowed(sizes: [cap - 1, 1]))
        #expect(!Shelf.isDropAllowed(sizes: [cap, 1]))
        #expect(!Shelf.isDropAllowed(sizes: [cap / 2 + 1, cap / 2 + 1]))
    }

    @Test func dropSizeCapSumsAcrossFilesAndSurvivesOverflow() {
        #expect(!Shelf.isDropAllowed(sizes: [Int64.max, Int64.max]))
        #expect(Shelf.isDropAllowed(sizes: []))
    }

    @Test func indexRoundTripKeepsSubSecondModificationDate() throws {
        let original = item(modified: 5.25)
        let decoded = try #require(Shelf.decodeIndex(try Shelf.encodeIndex([original])))
        #expect(decoded.items == [original])
        #expect(Shelf.inserting(original, into: decoded.items).replaced.count == 1)
    }

    @Test func decodeIndexDropsOnlyTheBadRow() throws {
        let good = item()
        var rows = try #require(
            JSONSerialization.jsonObject(with: Shelf.encodeIndex([good])) as? [[String: Any]])
        rows.append(["id": "not-a-uuid"])
        let data = try JSONSerialization.data(withJSONObject: rows)
        let decoded = try #require(Shelf.decodeIndex(data))
        #expect(decoded.items == [good])
        #expect(decoded.dropped == 1)
    }

    @Test func decodeIndexRejectsNonArray() {
        #expect(Shelf.decodeIndex(Data("{".utf8)) == nil)
        #expect(Shelf.decodeIndex(Data("{}".utf8)) == nil)
    }

    @Test func rebuiltMakesOneItemPerSingleEntryUUIDFolder() {
        let id = UUID()
        let known = UUID()
        let created = Date(timeIntervalSince1970: 42)
        let folders = [
            Shelf.FolderListing(name: id.uuidString, entries: ["a.txt"], created: created, byteSize: 7),
            Shelf.FolderListing(name: known.uuidString, entries: ["k.txt"], created: created, byteSize: 1),
            Shelf.FolderListing(name: UUID().uuidString, entries: [], created: created, byteSize: 0),
            Shelf.FolderListing(name: UUID().uuidString, entries: ["x", "y"], created: created, byteSize: 0),
            Shelf.FolderListing(name: "junk", entries: ["z"], created: created, byteSize: 0),
        ]
        let result = Shelf.rebuilt(from: folders, knownIDs: [known])
        #expect(result.count == 1)
        #expect(result[0].id == id)
        #expect(result[0].fileName == "a.txt")
        #expect(result[0].relativePath == "\(id.uuidString)/a.txt")
        #expect(result[0].addedAt == created)
        #expect(result[0].byteSize == 7)
        #expect(result[0].sourcePath.isEmpty)
    }

    @Test func rebuiltItemsNeverDedupe() {
        let id = UUID()
        let rebuilt = Shelf.rebuilt(
            from: [Shelf.FolderListing(name: id.uuidString, entries: ["a.txt"], created: now, byteSize: 1)])
        let new = item()
        #expect(Shelf.inserting(new, into: rebuilt).replaced.isEmpty)
    }
}
