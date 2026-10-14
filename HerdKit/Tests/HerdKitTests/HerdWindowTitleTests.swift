import Foundation
import HerdKit
import Testing

/// Covers the rule that decides whether a terminal window title belongs to a given herdr session.
///
/// The rule used to be a substring test, which is why these tests exist: raising session `default` would
/// have matched a window belonging to `default2`, every call would have reported success, and the user would
/// have been thrown into the wrong terminal with nothing to explain it. The decorated forms are taken from
/// live readings rather than invented: iTerm2 reports `herdr: default (herdr)`, appending the foreground job
/// in parentheses, and Terminal.app appends the shell and pane size after a spaced em dash.
struct HerdWindowTitleTests {

    @Test func markerIsTheSessionNameAfterAStablePrefix() {
        #expect(HerdrClient.windowTitle(for: "default") == "herdr: default")
        #expect(HerdrClient.windowTitle(for: "oncall_20-23_07") == "herdr: oncall_20-23_07")
    }

    @Test func undecoratedTitleMatchesItsOwnSession() {
        #expect(HerdrClient.windowTitle("herdr: default", isFor: "default"))
    }

    @Test func iTermJobSuffixStillMatches() {
        #expect(HerdrClient.windowTitle("herdr: default (herdr)", isFor: "default"))
        #expect(HerdrClient.windowTitle("herdr: hail_mary (herdr)", isFor: "hail_mary"))
        // A different foreground job, which is what the title says once the user runs something else.
        #expect(HerdrClient.windowTitle("herdr: default (-zsh)", isFor: "default"))
    }

    @Test func terminalAppSuffixStillMatches() {
        #expect(
            HerdrClient.windowTitle(
                "herdr: default \u{2014} -zsh \u{2014} 120\u{00D7}30", isFor: "default"
            )
        )
    }

    /// The regression this rule exists for.
    @Test func aLongerSessionNameSharingTheSamePrefixDoesNotMatch() {
        #expect(!HerdrClient.windowTitle("herdr: default2", isFor: "default"))
        #expect(!HerdrClient.windowTitle("herdr: default2 (herdr)", isFor: "default"))
        #expect(!HerdrClient.windowTitle("herdr: default_old (herdr)", isFor: "default"))
        #expect(!HerdrClient.windowTitle("herdr: default-backup (herdr)", isFor: "default"))
        // And the other direction: the shorter session must not claim the longer one's window either.
        #expect(!HerdrClient.windowTitle("herdr: default (herdr)", isFor: "default2"))
    }

    @Test func unrelatedTitlesDoNotMatch() {
        #expect(!HerdrClient.windowTitle("caffeinate (caffeinate)", isFor: "default"))
        #expect(!HerdrClient.windowTitle("~ (-zsh)", isFor: "default"))
        // The old undifferentiated title every attached herdr window carried before markers existed.
        #expect(!HerdrClient.windowTitle("herdr (herdr)", isFor: "default"))
        // A marker mentioned inside some other text is not this session's window: matching it was the
        // substring behaviour being removed.
        #expect(!HerdrClient.windowTitle("vim herdr: default (vim)", isFor: "default"))
    }

    @Test func prefixesCoverBothKnownSeparators() {
        let prefixes = HerdrClient.windowTitlePrefixes(for: "default")
        #expect(prefixes == ["herdr: default (", "herdr: default \u{2014} "])
    }
}
