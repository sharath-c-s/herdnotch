import Foundation
import HerdKit
import Testing

struct ApprovalBookTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func req(_ session: String) -> HookRequest { HookRequest(sessionID: session, toolName: "Bash") }
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func addSupersedesOlderEntryOfSameSession() {
        var book = ApprovalBook()
        #expect(book.add(req("a"), token: 1, now: t0).isEmpty)
        #expect(book.add(req("b"), token: 2, now: t0).isEmpty)
        #expect(book.add(req("a"), token: 3, now: at(1)) == [1])
        #expect(book.all.map(\.token) == [2, 3])
        #expect(book.pending(sessionID: "a")?.token == 3)
    }

    @Test func resolveRemovesAndReturnsEntry() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 7, now: t0)
        #expect(book.resolve(token: 7)?.request.sessionID == "a")
        #expect(book.resolve(token: 7) == nil)
        #expect(book.all.isEmpty)
    }

    @Test func resolveOfSupersededTokenReturnsNilAndKeepsNewerEntry() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 1, now: t0)
        _ = book.add(req("a"), token: 2, now: at(1))
        #expect(book.resolve(token: 1) == nil)
        #expect(book.all.map(\.token) == [2])
    }

    @Test func dropRemovesByToken() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 7, now: t0)
        book.drop(token: 99)
        #expect(book.all.count == 1)
        book.drop(token: 7)
        #expect(book.all.isEmpty)
    }

    @Test func unknownSessionReleasedAfterThreeSeconds() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 1, now: t0)
        #expect(book.sweep(now: at(2.9), knownSessionIDs: [], blockedSessionIDs: []).isEmpty)
        #expect(book.sweep(now: at(3), knownSessionIDs: [], blockedSessionIDs: []) == [1])
        #expect(book.all.isEmpty)
    }

    @Test func knownBlockedSessionIsKept() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 1, now: t0)
        for s in stride(from: 0.0, through: 30, by: 1) {
            #expect(book.sweep(now: at(s), knownSessionIDs: ["a"], blockedSessionIDs: ["a"]).isEmpty)
        }
    }

    @Test func notBlockedIgnoredDuringArrivalGrace() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 1, now: t0)
        #expect(book.sweep(now: at(1), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        // First observation after grace only starts the clock.
        #expect(book.sweep(now: at(2), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        #expect(book.pending(sessionID: "a")?.notBlockedSince == at(2))
        #expect(book.sweep(now: at(3.9), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        #expect(book.sweep(now: at(4), knownSessionIDs: ["a"], blockedSessionIDs: []) == [1])
    }

    @Test func beingBlockedAgainResetsNotBlockedClock() {
        var book = ApprovalBook()
        _ = book.add(req("a"), token: 1, now: t0)
        #expect(book.sweep(now: at(3), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        #expect(book.sweep(now: at(4), knownSessionIDs: ["a"], blockedSessionIDs: ["a"]).isEmpty)
        #expect(book.pending(sessionID: "a")?.notBlockedSince == nil)
        #expect(book.sweep(now: at(5), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        #expect(book.sweep(now: at(6.9), knownSessionIDs: ["a"], blockedSessionIDs: []).isEmpty)
        #expect(book.sweep(now: at(7), knownSessionIDs: ["a"], blockedSessionIDs: []) == [1])
    }
}
