import Foundation

/// What `client.window_title.set` reported.
///
/// The reason this type exists at all is the interesting part. Whether a herdr session has a terminal
/// attached is not observable from the filesystem: `herdr-client.sock` is created by the server, not by a
/// client, so its presence proves nothing, and that negative control was checked twice. But
/// `client.window_title.set` answers the question directly as a side effect of doing its job, because it
/// cannot set a title without a foreground client to set it on. One round trip, authoritative.
///
/// This matters because it explains a real bug rather than a hypothetical one. A session can be running
/// with live agents and no terminal attached to it. Clicking such an agent focuses the pane server-side,
/// every call succeeds, and nothing appears to happen, because there was never a window to bring forward.
/// The panel was rendering a detached session as though it were switchable.
public struct HerdWindowTitleResult: Codable, Sendable, Equatable {
    /// Whether herdr actually applied the title.
    public let changed: Bool

    /// herdr's explanation. `set` when applied, `no_foreground_client` when nothing is attached.
    ///
    /// Kept as a raw string rather than an enum so an unrecognised future reason cannot fail the decode,
    /// which would turn an informational probe into a hard error at exactly the wrong moment.
    public let reason: String

    /// herdr's reason string for a running session with no client attached.
    public static let noForegroundClient = "no_foreground_client"

    /// Whether this response proves nothing is attached to the session.
    ///
    /// Deliberately not `!changed`: herdr could report an unchanged title for a benign reason, such as the
    /// title already matching what was asked for, and treating that as "detached" would mark a perfectly
    /// attached session as broken. Only the explicit reason counts.
    public var isDetached: Bool { reason == Self.noForegroundClient }

    /// Memberwise initialiser, public so tests can build fixtures.
    ///
    /// - Parameters:
    ///   - changed: Whether herdr applied the title.
    ///   - reason: herdr's explanation.
    public init(changed: Bool, reason: String) {
        self.changed = changed
        self.reason = reason
    }
}

public extension HerdrClient {
    /// The title stamped on a session's attached terminal window.
    ///
    /// Stable and human-readable rather than an opaque token, and that is a product decision, not a
    /// convenience. Before this, every attached herdr window was titled `herdr (herdr)`, so two attached
    /// sessions were indistinguishable both to the user and to any code trying to find one of them. A
    /// per-session title fixes both problems with the same string.
    ///
    /// - Parameter sessionName: The session to name.
    /// - Returns: The window title to stamp.
    static func windowTitle(for sessionName: String) -> String {
        "herdr: \(sessionName)"
    }

    /// Separators a terminal emulator puts between the title it was asked to set and the text it appends
    /// on its own.
    ///
    /// A terminal does not show the requested title verbatim. iTerm2 reports a session whose title was set
    /// to `herdr: default` as `herdr: default (herdr)`, appending the foreground job in parentheses;
    /// Terminal.app appends the shell and the pane size after a spaced em dash. Both were read off the live
    /// machine rather than assumed, and they are the reason the window search cannot simply compare for
    /// equality.
    ///
    /// The `\u{2014}` escape is an em dash written as its code point, so that no editor or copy-paste step
    /// can silently turn it into a hyphen and quietly break Terminal.app matching.
    static let windowTitleSuffixSeparators = [" (", " \u{2014} "]

    /// The forms a terminal may show for a session's stamped title, other than the title itself.
    ///
    /// - Parameter sessionName: The session whose marker is being matched.
    /// - Returns: One prefix per separator in ``windowTitleSuffixSeparators``, each of which a decorated
    ///   title must begin with in order to belong to `sessionName`.
    static func windowTitlePrefixes(for sessionName: String) -> [String] {
        let marker = windowTitle(for: sessionName)
        return windowTitleSuffixSeparators.map { marker + $0 }
    }

    /// Whether a terminal window or tab title identifies exactly this session.
    ///
    /// Exact rather than a substring test, and that is a bug fix rather than tidying. The window search
    /// used to ask whether the title *contained* `herdr: <session>`, so raising session `default` would
    /// have matched a window belonging to a session named `default2`, `default_old` or `default-backup`,
    /// and the user would have been thrown into the wrong terminal with every call reporting success. The
    /// title has to either be the marker outright or be the marker followed by one of the separators a
    /// terminal is known to append after, which is what makes `default2` fail: its own title starts
    /// `herdr: default2`, and no separator follows `herdr: default` in it.
    ///
    /// - Parameters:
    ///   - title: A title read from a terminal window, tab or session.
    ///   - sessionName: The herdr session being looked for.
    /// - Returns: `true` when `title` is this session's stamped marker, decorated or not.
    static func windowTitle(_ title: String, isFor sessionName: String) -> Bool {
        if title == windowTitle(for: sessionName) { return true }
        return windowTitlePrefixes(for: sessionName).contains(where: title.hasPrefix)
    }

    /// Sets the attached client's window title, and reports whether there was a client at all.
    ///
    /// Two jobs in one call, on purpose. The title is the discriminator a window search needs, and the
    /// response is the attachment probe. Doing them separately would mean two round trips and a race:
    /// terminals apply a title asynchronously, so a title set immediately before a window search may not
    /// be visible yet, which is why a persistently stamped title is better than a just-in-time one.
    ///
    /// - Parameters:
    ///   - title: The title to apply.
    ///   - timeout: Budget for the whole exchange.
    /// - Returns: Whether the title was applied, and herdr's reason.
    /// - Throws: Any ``HerdrError``. ``HerdrError/socketUnavailable(_:)`` means the session is not running,
    ///   which is a different thing from running-but-detached and must not be conflated with it.
    func setWindowTitle(_ title: String, timeout: TimeInterval = 2.0) throws -> HerdWindowTitleResult {
        let data = try call("client.window_title.set", params: ["title": .string(title)], timeout: timeout)
        return try HerdJSON.decoder.decode(HerdWindowTitleResult.self, from: data)
    }

    /// Clears the attached client's window title, restoring whatever the terminal shows by default.
    ///
    /// - Parameter timeout: Budget for the whole exchange.
    /// - Throws: Any ``HerdrError``.
    func clearWindowTitle(timeout: TimeInterval = 2.0) throws {
        _ = try call("client.window_title.clear", timeout: timeout)
    }
}
