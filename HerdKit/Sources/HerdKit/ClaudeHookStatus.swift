import Foundation

/// Whether HerdNotch's PermissionRequest hook is registered in Claude Code's user settings.
public enum ClaudeHookStatus {
    /// True when any `hooks.PermissionRequest[*].hooks[*].command` contains the hook flag.
    public static func isInstalled(settingsJSON: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any],
            let groups = hooks["PermissionRequest"] as? [[String: Any]]
        else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.contains(PermissionHookClient.flag) == true
            }
        }
    }

    /// Installed when `$CLAUDE_CONFIG_DIR/settings.json` (if set) or `~/.claude/settings.json` has the hook.
    ///
    /// Both are checked because a Finder launch does not inherit the shell's `CLAUDE_CONFIG_DIR`.
    public static func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        var dirs = [home.appendingPathComponent(".claude")]
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            dirs.insert(URL(fileURLWithPath: custom), at: 0)
        }
        return dirs.contains { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("settings.json"))).map { isInstalled(settingsJSON: $0) }
                ?? false
        }
    }
}
