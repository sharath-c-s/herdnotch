import Foundation

/// Finds every herdr session on this machine and decides which ones are alive.
///
/// Re-implements what `herdr session list --json` does rather than shelling out to the CLI: a
/// directory scan plus a socket probe. That removes any assumption about where the `herdr` binary
/// lives, avoids a process spawn per poll, and works from inside an XPC helper that has no useful
/// `PATH`. Liveness is decided by whether `connect()` succeeds, which is exactly the CLI's own test,
/// so the panel and the CLI can never disagree about what is running.
///
/// Thread-safety: a `Sendable` value with no mutable state. ``discover()`` is synchronous and
/// blocking, so it belongs off the main thread.
public struct HerdrDiscovery: Sendable {
    /// herdr's configuration root, `~/.config/herdr`.
    ///
    /// Resolved from the current user's home directory. Inside a sandboxed process this points at
    /// the container and will contain nothing, which is why discovery runs in the unsandboxed helper.
    public static let defaultConfigRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".config/herdr", directoryHint: .isDirectory)

    /// Filename herdr uses for a session's server socket.
    ///
    /// Named explicitly because each session directory also contains a `herdr-client.sock`, which is
    /// a different endpoint and must not be probed.
    private static let socketFilename = "herdr.sock"

    /// Filename of the endpoint a herdr *client* connects to, which must never be treated as a session.
    ///
    /// It is created by the server, not by a client, so its presence proves nothing about attachment and
    /// probing it would report a session that does not exist. Local discovery avoids it by naming
    /// ``socketFilename`` outright; the extra-path scan has to exclude it explicitly, because a user who
    /// forwards a whole directory of sockets will have one of these in it.
    private static let clientSocketFilename = "herdr-client.sock"

    /// Suffix an extra path must carry to be taken as a session socket during a directory scan.
    private static let socketExtension = ".sock"

    /// Directory scanned for sessions.
    public let configRoot: URL

    /// Extra socket paths and directories to scan, over and above ``configRoot``.
    ///
    /// This is the whole of the remote-session feature, and it is deliberately the whole of it. herdr's
    /// `--remote <ssh-target>` is an attach mechanism rather than a session type: it bridges a client's
    /// stdin and stdout over SSH to a herdr server on the far host, so the session's socket exists only on
    /// that host and no amount of local scanning will find it. What *does* find it is
    /// `ssh -L /local/path:/remote/path`, which puts a Unix domain socket at a local path that proxies to
    /// the remote one. Once such a socket exists, every call in this library works against it unchanged,
    /// so the feature reduces to letting the user say where those paths are. No new protocol code, no SSH
    /// lifecycle management, and nothing to keep in sync with herdr.
    ///
    /// Each entry is interpreted by what is on disk at scan time:
    ///
    /// - An existing **directory**: every entry directly inside it whose name ends in `.sock`, except
    ///   ``clientSocketFilename``, becomes one session. This is what makes forwarding several remote
    ///   sockets into one directory work without listing each of them here.
    /// - Anything else, including a path that does not exist yet: **one** session at exactly that path.
    ///   A path that does not exist is still reported, as a stopped session, because a forward that is
    ///   down is the case the user most needs to see. A session that silently vanishes cannot be told
    ///   apart from a broken panel.
    ///
    /// Leading `~` is expanded, since these come from a text field a human typed into.
    public let extraPaths: [String]

    /// Per-socket liveness probe budget.
    ///
    /// Short on purpose. A user who has accumulated a dozen stopped sessions has a dozen stale socket
    /// files, and every one of them is probed on every discovery pass; a two second budget each would
    /// make the panel unusable. A local `AF_UNIX` connect either succeeds in microseconds or is
    /// refused immediately, so 300 ms is generous.
    public let probeTimeout: TimeInterval

    /// How probes are performed. Injected so tests can decide liveness without real servers.
    private let connector: any SocketConnecting

    /// Creates a discovery pass configuration.
    ///
    /// - Parameters:
    ///   - configRoot: Directory to scan. Defaults to ``defaultConfigRoot``.
    ///   - extraPaths: Additional socket paths or directories, for forwarded remote sessions. Defaults
    ///     to none, so local-only behaviour is unchanged unless a caller opts in.
    ///   - connector: Connection factory used for liveness probes.
    ///   - probeTimeout: Budget per probe. Defaults to 300 ms.
    public init(
        configRoot: URL = HerdrDiscovery.defaultConfigRoot,
        extraPaths: [String] = [],
        connector: any SocketConnecting = UnixSocketConnector(),
        probeTimeout: TimeInterval = 0.3
    ) {
        self.configRoot = configRoot
        self.extraPaths = extraPaths
        self.connector = connector
        self.probeTimeout = probeTimeout
    }

    /// Enumerates sessions and probes each one's socket.
    ///
    /// The default session is reported only when its socket file exists, because the socket is the
    /// only evidence that a default session was ever started. Named sessions are reported for every
    /// subdirectory of `sessions/`, socket file or not: the directory is the evidence there, and a
    /// session the user created must stay visible as "stopped" rather than disappear.
    ///
    /// ``extraPaths`` are scanned after the config root and their sessions carry
    /// ``HerdSession/isRemote``. A local session wins a name collision, because a name that means two
    /// things in the session filter would let one selection silently hide the other.
    ///
    /// - Returns: Sessions with empty `workspaces` and no `error`, already in display order: running
    ///   before stopped, local before remote, the default session first within its group, then by name.
    ///   Empty when ``configRoot`` does not exist and no extra paths are configured, which simply means
    ///   herdr has never run for this user.
    public func discover() -> [HerdSession] {
        var sessions = localSessions()
        sessions.append(contentsOf: remoteSessions(avoiding: Set(sessions.map(\.name))))
        return sessions.sorted(by: HerdSession.sortsBefore)
    }

    /// Sessions found under ``configRoot``, in scan order.
    private func localSessions() -> [HerdSession] {
        let fileManager = FileManager.default
        var sessions: [HerdSession] = []

        let defaultSocket = configRoot.appending(path: Self.socketFilename)
        if fileManager.fileExists(atPath: defaultSocket.path) {
            sessions.append(session(name: HerdSession.defaultSessionName, isDefault: true, socket: defaultSocket))
        }

        let sessionsRoot = configRoot.appending(path: "sessions", directoryHint: .isDirectory)
        let names = (try? fileManager.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            let directory = sessionsRoot.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            sessions.append(
                session(
                    name: name,
                    isDefault: false,
                    socket: directory.appending(path: Self.socketFilename)
                )
            )
        }

        return sessions
    }

    /// Sessions found through ``extraPaths``, in the order the paths were configured.
    ///
    /// - Parameter taken: Names already in use by local sessions, so a remote one cannot shadow them.
    /// - Returns: Remote session descriptors, each already probed for liveness.
    private func remoteSessions(avoiding taken: Set<String>) -> [HerdSession] {
        var used = taken
        var sessions: [HerdSession] = []
        for socketPath in Self.remoteSocketPaths(for: extraPaths) {
            let name = Self.uniqueName(Self.sessionName(forSocketPath: socketPath), avoiding: used)
            used.insert(name)
            sessions.append(
                HerdSession(
                    name: name,
                    isDefault: false,
                    running: isReachable(socketPath: socketPath),
                    socketPath: socketPath,
                    isRemote: true
                )
            )
        }
        return sessions
    }

    /// Expands the configured extra paths into the concrete socket paths to probe.
    ///
    /// Duplicates are dropped, so listing both a directory and one socket inside it cannot produce the
    /// same session twice.
    ///
    /// - Parameter paths: The configured entries, possibly containing `~`, surrounding spaces, or blanks.
    /// - Returns: Absolute socket paths, in configuration order.
    private static func remoteSocketPaths(for paths: [String]) -> [String] {
        let fileManager = FileManager.default
        var out: [String] = []
        var seen: Set<String> = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)
            let candidates: [String]
            if exists, isDirectory.boolValue {
                let entries = (try? fileManager.contentsOfDirectory(atPath: expanded)) ?? []
                candidates = entries
                    .filter { $0.hasSuffix(socketExtension) && $0 != clientSocketFilename }
                    .sorted()
                    .map { (expanded as NSString).appendingPathComponent($0) }
            } else {
                candidates = [expanded]
            }
            for candidate in candidates where seen.insert(candidate).inserted {
                out.append(candidate)
            }
        }
        return out
    }

    /// The session name to show for a forwarded socket.
    ///
    /// Derived from the path because a forwarded socket carries no other identity: the far side's session
    /// name is not observable until the socket answers, and a name is needed before that in order to draw
    /// a stopped row at all. The user therefore names a remote session by choosing where to forward it,
    /// which is the same way they name a local one by choosing `herdr --session <name>`.
    ///
    /// `herdr.sock` and `herdr` fall back to the containing directory's name, so a remote config root
    /// forwarded to `~/.herd-remote/prod/herdr.sock` shows as `prod` rather than as `herdr`.
    ///
    /// - Parameter path: Absolute socket path.
    /// - Returns: A display name, never empty.
    private static func sessionName(forSocketPath path: String) -> String {
        let url = URL(filePath: path)
        let base = url.lastPathComponent
        if base == socketFilename || base == "herdr" {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" { return parent }
        }
        let stripped = base.hasSuffix(socketExtension)
            ? String(base.dropLast(socketExtension.count))
            : base
        return stripped.isEmpty ? base : stripped
    }

    /// `name`, or `name (2)`, `name (3)` … until it is unused.
    ///
    /// Names are the session filter's keys and SwiftUI's row identities, so two sessions sharing one is
    /// not cosmetic: deselecting one would deselect both, and the list would carry duplicate identities.
    ///
    /// - Parameters:
    ///   - name: Preferred name.
    ///   - taken: Names already in use.
    /// - Returns: An unused name.
    private static func uniqueName(_ name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) (\(suffix))") { suffix += 1 }
        return "\(name) (\(suffix))"
    }

    /// Builds one session descriptor, probing its socket for liveness.
    private func session(name: String, isDefault: Bool, socket: URL) -> HerdSession {
        HerdSession(
            name: name,
            isDefault: isDefault,
            running: isReachable(socketPath: socket.path),
            socketPath: socket.path
        )
    }

    /// Probes a socket by connecting and immediately closing.
    ///
    /// No request is sent: a successful `connect()` is the whole test, and sending one would double
    /// the cost of discovery for no extra information.
    ///
    /// - Parameter socketPath: Absolute path of the socket to probe.
    /// - Returns: `true` if a connection was established.
    private func isReachable(socketPath: String) -> Bool {
        guard let connection = try? connector.connect(path: socketPath, timeout: probeTimeout) else {
            return false
        }
        connection.close()
        return true
    }
}
