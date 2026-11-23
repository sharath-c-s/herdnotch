import Foundation
import Testing

@testable import NotchCore

@Suite struct ReminderFlowTests {
    @Test func escapeClearsTextFirst() {
        #expect(ReminderEscape.action(text: "x", returnsToPage: true) == .clearText)
        #expect(ReminderEscape.action(text: "x", returnsToPage: false) == .clearText)
    }

    @Test func escapeOnEmptyTextGoesBackOrCollapses() {
        #expect(ReminderEscape.action(text: "", returnsToPage: true) == .backToPage)
        #expect(ReminderEscape.action(text: "", returnsToPage: false) == .collapse)
    }

    @Test func openFromClosedStatesOpens() {
        for state in [NotchPresentation.collapsed, .collapsing] {
            #expect(ReminderOpen.action(presentation: state, current: nil, requested: .compose) == .open)
        }
        #expect(ReminderOpen.action(presentation: nil, current: nil, requested: .list) == .open)
    }

    @Test func expandedSameModeClosesOtherModeSwitches() {
        let expanded = NotchPresentation.expanded(.home)
        #expect(ReminderOpen.action(presentation: expanded, current: .compose, requested: .compose) == .close)
        #expect(ReminderOpen.action(presentation: expanded, current: .list, requested: .compose) == .switchMode)
        #expect(ReminderOpen.action(presentation: expanded, current: nil, requested: .list) == .switchMode)
    }

    @Test func midAnimationOrSuspendedIgnores() {
        #expect(ReminderOpen.action(presentation: .expanding(.hotkey), current: nil, requested: .list) == .ignore)
        #expect(ReminderOpen.action(presentation: .suspended, current: nil, requested: .compose) == .ignore)
    }
}
