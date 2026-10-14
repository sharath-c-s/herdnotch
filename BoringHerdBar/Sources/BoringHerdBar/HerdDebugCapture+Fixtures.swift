import AppKit
import Foundation
import HerdHost
import HerdKit
import HerdPanelUI
import SwiftUI

/// The one ``HerdDebugCapture`` caller that stayed in this target rather than moving to `HerdHost` with
/// the type itself: it renders ``HerdFixtureSnapshot``, a fixture fabricated for this app's own design
/// review, which is not something either host's model layer needs and therefore has no business in a
/// library both apps share. See ``HerdDebugCapture``'s own documentation for the rest of this split.
extension HerdDebugCapture {
    /// Renders the ledger against the fixture snapshot, off screen, in both the mixed and all-idle states.
    ///
    /// This is the part of the throwaway prototype harness worth keeping, and only this part. The live
    /// capture path photographs whatever the herd happens to be doing at that second, which means the
    /// all-idle day cannot be captured on demand: you cannot ask sixteen real agents to go quiet. Since
    /// all-idle is what the user sees most and the state the design is judged on, it needs a fixture.
    ///
    /// The window is real but never ordered in. `cacheDisplay` on a view with no window produces an
    /// unscaled and usually empty frame, whereas with one it inherits the backing scale factor, which is
    /// what makes 9 pt type legible in the PNG.
    ///
    /// - Parameters:
    ///   - directory: Absolute directory to write `ledger-mixed.png` and `ledger-allidle.png` into.
    ///   - recentlyCompleted: Recency keys to render, so the checkmark and the urgency ordering it explains
    ///     both appear in the capture.
    static func writeFixtures(into directory: String, recentlyCompleted: Set<String>) {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let states = [
            ("ledger-mixed", HerdFixtureSnapshot.mixed),
            ("ledger-allidle", HerdFixtureSnapshot.allIdle)
        ]
        for (name, fixture) in states {
            let ordered = HerdUrgencyOrder.applying(recentlyCompleted: recentlyCompleted, to: fixture)
            let root = HerdLedgerView(
                snapshot: ordered,
                recentlyCompleted: recentlyCompleted,
                // `oncall_20-23_07` is the user's own detached session, so the fixture renders the marker
                // in the place they will actually see it.
                detachedSessions: ["oncall_20-23_07"],
                // The shipped scale, so a fixture capture shows the panel at the size a user gets. An
                // override is honoured so the harness can photograph the extreme steps and check that
                // sixteen agents still fit without a scroll.
                scale: HerdLedgerScale(identifierSize: Self.requestedTextSize),
                banner: nil,
                bannerIsError: false,
                onSelectAgent: { _, _ in },
                onSelectSession: { _ in },
                onSelectWorkspace: { _, _ in },
                onDismiss: {}
            )
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            write(hosting, to: "\(directory)/\(name).png")
            FileHandle.standardError.write(
                Data("herd: fixture \(name) \(hosting.bounds.size)\n".utf8)
            )
            window.contentView = nil
        }
    }

    /// The identifier size a fixture capture should render at.
    ///
    /// `HERDBAR_TEXT_SIZE` overrides the shipped default so the harness can photograph the extreme steps of
    /// the type scale, which is the only way to check that sixteen agents still fit without a scroll at the
    /// largest one. Anything unparseable falls back to the default rather than failing, since a capture is a
    /// diagnostic and should not be the thing that breaks.
    private static var requestedTextSize: CGFloat {
        guard let raw = ProcessInfo.processInfo.environment["HERDBAR_TEXT_SIZE"],
              let value = Double(raw), value > 0 else {
            return HerdLedgerScale.defaultIdentifierSize
        }
        return CGFloat(value)
    }
}
