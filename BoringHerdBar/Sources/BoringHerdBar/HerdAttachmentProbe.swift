import Foundation
import HerdKit

/// Finds out which running sessions have no terminal attached to them.
///
/// Why this is worth a type of its own: attachment is the difference between a click that works and a click
/// that silently does nothing, and it was believed to be undetectable. `herdr-client.sock` is created by the
/// server rather than by a client, so its presence proves nothing, and that negative control was checked
/// twice. The answer turned out to come from `client.window_title.set`, which cannot apply a title without a
/// foreground client and reports `no_foreground_client` when there is none.
///
/// The probe therefore writes, which is the one uncomfortable thing about it. It sets each session's window
/// title to `herdr: <session>` and leaves it there. That is a deliberate product decision rather than a
/// shortcut, and it is defensible on its own merits: herdr titles every attached window `herdr (herdr)`, so
/// two attached sessions were previously indistinguishable in the user's own window list. A per-session
/// title is strictly more informative, is idempotent so re-probing costs nothing visible, and is the
/// discriminator a window search needs anyway. The alternative, stamping and clearing on every probe, would
/// flicker the user's title bars once per panel open and reintroduce the asynchronous-title race.
///
/// Thread-safety: `Sendable` and stateless. Every call opens its own sockets and is expected to run off the
/// main actor, because each one is a blocking round trip per session.
struct HerdAttachmentProbe: Sendable {

    /// Probes every running session and reports which ones have nothing attached.
    ///
    /// Stopped sessions are skipped rather than reported: a stopped session has no server to ask, and the
    /// panel already renders it as stopped. Conflating "stopped" with "detached" would tell the user to
    /// attach a client to a session that is not running.
    ///
    /// A session whose probe throws is also omitted. The failure modes are a session that stopped between
    /// the snapshot and this call, or a wedged server, and in both cases claiming the session is detached
    /// would be a guess dressed up as a fact. Omission means the panel shows no marker, which is the
    /// truthful "I do not know".
    ///
    /// - Parameter sessions: The sessions from the current snapshot.
    /// - Returns: Names of running sessions that reported `no_foreground_client`.
    func detachedSessionNames(in sessions: [HerdSession]) -> Set<String> {
        var detached: Set<String> = []
        for session in sessions where session.running {
            let client = HerdrClient(socketPath: session.socketPath)
            do {
                let result = try client.setWindowTitle(HerdrClient.windowTitle(for: session.name))
                if result.isDetached { detached.insert(session.name) }
            } catch {
                FileHandle.standardError.write(
                    Data("herd: attachment probe for \(session.name) failed: \(error)\n".utf8)
                )
            }
        }
        return detached
    }
}
