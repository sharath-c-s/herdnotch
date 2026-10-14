import Foundation

/// AppleScript that selects the iTerm2 session or Terminal.app tab whose `tty` matches.
public enum TerminalTTYScript {
    /// Escapes a string for a double-quoted AppleScript literal. Backslashes first, so the quote pass
    /// cannot double-escape the ones it adds.
    public static func escapedLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// - Parameter tty: Bare device name such as `ttys004`; the script compares against `/dev/<tty>`.
    /// Returns `"found"` or `"notfound"`, wrapped in a 2 s timeout.
    public static func script(iTerm2: Bool, tty: String) -> String {
        let literal = escapedLiteral("/dev/" + tty)
        if iTerm2 {
            return """
            with timeout of 2 seconds
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(literal)" then
                                    select w
                                    tell w to select t
                                    tell s to select
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "notfound"
                end tell
            end timeout
            """
        }
        return """
        with timeout of 2 seconds
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(literal)" then
                            set index of w to 1
                            set selected tab of w to t
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
                return "notfound"
            end tell
        end timeout
        """
    }
}

/// tmux command lines and output parsing for jumping to a pane. Every command is an argv array.
public enum TmuxJump {
    public static let listPanesArgs = ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]
    public static let listClientsArgs = ["list-clients", "-F", "#{client_tty} #{client_pid} #{client_session}"]

    public struct Pane: Equatable, Sendable {
        /// Bare tty name.
        public let tty: String
        public let session: String
        public let window: String
        public let pane: String
        public var windowTarget: String { "\(session):\(window)" }
        public var paneTarget: String { "\(session):\(window).\(pane)" }
    }

    public struct Client: Equatable, Sendable {
        public let tty: String
        public let pid: Int32
        public let session: String
    }

    /// The pane showing bare tty `tty`, from `list-panes` output.
    public static func findPane(tty: String, in output: String) -> Pane? {
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let device = bare(String(line[..<space]))
            let target = line[line.index(after: space)...]
            // tmux forbids ':' in session names, so the last ':' separates session from window.pane.
            guard device == tty, let colon = target.lastIndex(of: ":") else { continue }
            let rest = target[target.index(after: colon)...].split(separator: ".", maxSplits: 1)
            guard rest.count == 2 else { continue }
            return Pane(tty: device, session: String(target[..<colon]), window: String(rest[0]), pane: String(rest[1]))
        }
        return nil
    }

    /// The client attached to `session`, else the first client.
    public static func pickClient(for session: String, in output: String) -> Client? {
        let clients: [Client] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let pid = Int32(parts[1]) else { return nil }
            return Client(tty: bare(String(parts[0])), pid: pid, session: String(parts[2]))
        }
        return clients.first { $0.session == session } ?? clients.first
    }

    /// The commands that point tmux at `pane`, in order.
    public static func selectCommands(pane: Pane, client: Client?) -> [[String]] {
        var switchClient = ["switch-client"]
        if let client { switchClient += ["-c", "/dev/" + client.tty] }
        switchClient += ["-t", pane.session]
        return [switchClient, ["select-window", "-t", pane.windowTarget], ["select-pane", "-t", pane.paneTarget]]
    }

    private static func bare(_ device: String) -> String {
        device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
    }
}
