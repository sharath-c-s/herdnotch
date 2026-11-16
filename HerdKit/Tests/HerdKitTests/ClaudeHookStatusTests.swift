import Foundation
import HerdKit
import Testing

struct ClaudeHookStatusTests {
    private func installed(_ json: String) -> Bool {
        ClaudeHookStatus.isInstalled(settingsJSON: Data(json.utf8))
    }

    @Test func detectsHookCommand() {
        let json = #"{"hooks":{"PermissionRequest":[{"matcher":"","hooks":[{"type":"command","command":"/Applications/HerdNotch.app/Contents/MacOS/HerdNotch --claude-permission-hook"}]}]}}"#
        #expect(installed(json))
    }

    @Test func ignoresOtherHooksAndEvents() {
        #expect(!installed(#"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"other"}]}]}}"#))
        #expect(!installed(#"{"hooks":{"PreToolUse":[{"hooks":[{"command":"x --claude-permission-hook"}]}]}}"#))
        #expect(!installed("{}"))
        #expect(!installed("not json"))
    }

    @Test func readsSettingsFromHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hookstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!ClaudeHookStatus.isInstalled(home: home, environment: [:]))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let file = home.appendingPathComponent(".claude/settings.json")
        try Data("{oops".utf8).write(to: file)
        #expect(!ClaudeHookStatus.isInstalled(home: home, environment: [:]))
        try Data(#"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"h --claude-permission-hook"}]}]}}"#.utf8).write(to: file)
        #expect(ClaudeHookStatus.isInstalled(home: home, environment: [:]))
    }

    @Test func eitherConfigDirOrHomeCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hookstatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let hooked = Data(#"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"h --claude-permission-hook"}]}]}}"#.utf8)
        let env = ["CLAUDE_CONFIG_DIR": custom.path]

        #expect(!ClaudeHookStatus.isInstalled(home: home, environment: env))
        try hooked.write(to: custom.appendingPathComponent("settings.json"))
        #expect(ClaudeHookStatus.isInstalled(home: home, environment: env))
        #expect(!ClaudeHookStatus.isInstalled(home: home, environment: [:]))
        try FileManager.default.removeItem(at: custom.appendingPathComponent("settings.json"))
        try hooked.write(to: home.appendingPathComponent(".claude/settings.json"))
        #expect(ClaudeHookStatus.isInstalled(home: home, environment: env))
    }
}
