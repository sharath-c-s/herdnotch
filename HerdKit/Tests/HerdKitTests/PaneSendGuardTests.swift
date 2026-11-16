import HerdKit
import Testing

struct PaneSendGuardTests {
    @Test func sameRevisionAfterASendIsRefused() {
        #expect(!PaneSendGuard.allows(freshRevision: 7, lastSentRevision: 7))
    }

    @Test func newRevisionOrNoPriorSendIsAllowed() {
        #expect(PaneSendGuard.allows(freshRevision: 8, lastSentRevision: 7))
        #expect(PaneSendGuard.allows(freshRevision: 7, lastSentRevision: nil))
    }
}
