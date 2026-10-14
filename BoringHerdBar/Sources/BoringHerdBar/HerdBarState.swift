import Foundation

/// What the data layer currently knows, beyond the snapshot itself.
///
/// Lives in the host app rather than in `HerdPanelUI`, and that is the change the ledger forced. While the
/// panel took this enum as a parameter it had to live in the module the fork consumes; the ledger takes a
/// banner sentence and an is-error flag instead, which is a smaller contract that cannot drift, so the enum
/// went back to the app that produces it. The mapping happens once, in ``HerdPanel``.
///
/// The three cases are deliberately not collapsed into a single "something went wrong": the user action
/// that resolves each one is different. ``noSessions`` means install or start herdr, ``error`` means herdr
/// is there but not answering, and only ``ok`` means the rows are trustworthy.
enum HerdBarState: Equatable, Sendable {
    /// At least one running session answered, so the snapshot reflects reality.
    case ok
    /// Nothing to watch: no sessions were discovered, or none of the discovered ones is running. The
    /// payload is a sentence the user can act on.
    case noSessions(String)
    /// Sessions are running but every one of them failed to answer. The payload is the reason.
    case error(String)
}
