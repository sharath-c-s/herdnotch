import AppKit
import Foundation
import HerdHost
import HerdKit
import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI

/// `HERDNOTCH_PREVIEW_DUMP=<dir>`: renders the agents card with the preview expanded, once per route state and
/// card size, as dark PNGs. Never runs unless the variable is set.
@MainActor
enum PreviewDebugDump {
    private struct Sample {
        let name: String
        let route: PreviewRoute
        var tail: [String] = []
    }

    private static let menu = """
        Bash command

          mvnd verify -pl loader

        Do you want to proceed?
        \u{276F} 1. Yes
          2. Yes, and don't ask again for mvnd commands
          3. No
        """

    /// The real Claude Code Bash permission menu (four options), as captured from a pane.
    private static let claudeMenu = """
        \u{276F} Run this exact bash command once and nothing else: mkfifo spikepipe_one
        \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
         Bash command

         Create named pipe spikepipe_one
        \u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}
         mkfifo spikepipe_one
        \u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}\u{254C}
         This command requires approval

         Do you want to proceed?
         \u{276F} 1. Yes
           2. Yes, and don\u{2019}t ask again for: mkfifo spikepipe_one *
           3. Yes, and switch to auto mode \u{00B7} auto mode handles these prompts for you
           4. No

         Esc to cancel \u{00B7} Tab to amend
        """

    private static func hook(_ tool: String, _ input: JSONValue) -> PreviewRoute {
        let approval = PendingApproval(
            token: 1,
            request: HookRequest(
                sessionID: "s", toolName: tool, toolInput: input,
                permissionSuggestions: [.object(["type": .string("addRules")])]),
            arrivedAt: Date())
        return PreviewRoute.resolve(approval: approval, paneText: nil)
    }

    private static var samples: [Sample] {
        let ask = JSONValue.object(["questions": .array([.object([
            "question": .string("Which database should the loader target?"),
            "options": .array(["Postgres", "MySQL", "SQLite"].map { .object(["label": .string($0)]) }),
        ])])])
        let edit = JSONValue.object([
            "file_path": .string("/src/Loader.swift"),
            "old_string": .string("let batch = 100\nlet retries = 3"),
            "new_string": .string("let batch = 500\nlet retries = 5\nlet timeout = 30"),
        ])
        let bash = JSONValue.object([
            "command": .string("mvnd verify -pl loader -Djacoco.skip=false -DskipITs=false -Dmaven.test.failure.ignore=true"),
            "description": .string("Run the loader verify build"),
        ])
        let longBash = JSONValue.object([
            "command": .string(
                (0..<14).map { "curl -sS https://example.com/api/v1/items/\($0)?expand=all" }.joined(separator: " && ")),
        ])
        let tail = [
            "Reading catalog_diff.sql", "Running 14 tests in LoaderTests", "\u{2713} 12 passed", "\u{2717} 2 failed",
            "Fixing the batch size assertion", "Editing LoaderTests.swift",
        ]
        return [
            Sample(name: "hook-bash", route: hook("Bash", bash)),
            Sample(name: "hook-bash-long", route: hook("Bash", longBash)),
            Sample(name: "hook-edit", route: hook("Edit", edit)),
            Sample(name: "hook-ask", route: hook("AskUserQuestion", ask)),
            Sample(name: "pane-menu", route: PreviewRoute.resolve(approval: nil, paneText: menu)),
            Sample(name: "pane-menu-claude4", route: PreviewRoute.resolve(approval: nil, paneText: claudeMenu)),
            Sample(name: "preview-only", route: .previewOnly, tail: tail),
        ]
    }

    static func run(into directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let preferred = CGSize(
            width: NotchPreferences.expandedWidthDefault, height: NotchPreferences.expandedHeightDefault)
        let minimum = CGSize(width: preferred.width, height: CGFloat(NotchPreferences.expandedHeightRange.lowerBound))
        for (label, panel) in [("default", preferred), ("min", minimum)] {
            let size = BentoLayout(panel: panel).agents.size
            for sample in samples {
                let view = NSHostingView(rootView: card(sample, size: size))
                view.frame = NSRect(origin: .zero, size: size)
                HerdDebugCapture.write(view, to: "\(directory)/\(sample.name)-\(label).png")
            }
            runReminders(into: directory, label: label, panel: panel)
            runBand(into: directory, label: label)
        }
    }

    /// The full reminders view: compose with a typed time (chip visible), and the list with 0, 3 and 12 items.
    private static func runReminders(into directory: String, label: String, panel: CGSize) {
        let size = RemindersPanelView.frame(in: BentoLayout(panel: panel, shelfExpanded: false)).size
        let now = Date()
        func items(_ count: Int) -> [RemindersService.ReminderItem] {
            (0..<count).map { index in
                RemindersService.ReminderItem(
                    id: "sample-\(index)", title: "Sample reminder number \(index + 1)",
                    dueDate: index % 3 == 0 ? nil : now.addingTimeInterval(Double(index - 1) * 5400),
                    creationDate: now)
            }
        }
        let cases: [(String, ReminderMode, Int, String)] = [
            ("reminders-compose", .compose, 3, "call bank 5pm"),
            ("reminders-list-0", .list, 0, ""),
            ("reminders-list-3", .list, 3, ""),
            ("reminders-list-12", .list, 12, ""),
        ]
        for (name, mode, count, text) in cases {
            let view = NSHostingView(
                rootView: RemindersPanelView(
                    palette: .dark, mode: mode, items: items(count), authorizationState: .authorized, now: now,
                    returnsToPage: false, initialText: text, onAdd: { _ in }, onComplete: { _ in },
                    onRequestAccess: {}, onEscape: {}, onBack: {}
                )
                .frame(width: size.width, height: size.height)
                .background(HerdPalette.dark.cardFill)
                .environment(\.colorScheme, .dark))
            view.frame = NSRect(origin: .zero, size: size)
            HerdDebugCapture.write(view, to: "\(directory)/\(name)-\(label).png")
        }
    }

    /// The band's left flank (clock stack plus page switcher) for each selected page, with a fixed sample time.
    private static func runBand(into directory: String, label: String) {
        let size = CGSize(width: 244, height: 36)
        let palette = HerdPalette.dark
        for (name, page) in [("herd", NotchPage.herd), ("system", .system), ("health", .health)] {
            let view = NSHostingView(
                rootView: HStack(spacing: 16) {
                    BandClockView(clock: "23:37", date: "Mon 23", palette: palette)
                    PageSwitcherView(selected: page, palette: palette, onSelect: { _ in }, onHover: { _, _ in })
                    Spacer(minLength: 0)
                }
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
            view.frame = NSRect(origin: .zero, size: size)
            HerdDebugCapture.write(view, to: "\(directory)/band-\(name)-\(label).png")
        }
    }

    /// The agents card chrome (header, padding) around the expanded block and two rows; the footer is hidden.
    private static func card(_ sample: Sample, size: CGSize) -> some View {
        let palette = HerdPalette.dark
        let viewport = CGSize(width: size.width - 2 * 16, height: size.height - 2 * 16 - 18 - 10)
        return VStack(alignment: .leading, spacing: 10) {
            Text("AGENTS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
                .frame(height: 18)
            VStack(spacing: 0) {
                AgentPreviewCard(
                    palette: palette, status: .blocked, agentName: "catalog_diff", route: sample.route,
                    paneTail: sample.tail, fallbackText: "No output yet", isSent: false, viewport: viewport,
                    onHook: { _, _ in },
                    hookLines: { approval in
                        PreviewText.hookLines(
                            toolName: approval.request.toolName,
                            input: approval.request.toolInput.asAny as? [String: Any] ?? [:])
                    },
                    onPaneOption: { _, _ in }, onJump: { _ in }, onCollapse: {})
                row(palette, "demo-app", .working, "1m")
                row(palette, "demo-api", .idle, "4m")
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .top)
            .clipped()
        }
        .padding(16)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(palette.cardFill)
        .environment(\.colorScheme, .dark)
    }

    private static func row(_ palette: HerdPalette, _ name: String, _ status: AgentStatus, _ age: String) -> some View {
        NotchBreadcrumbRow(
            palette: palette, status: status, sessionName: "default", workspaceLabel: "w1", agentName: name,
            agentKind: "claude", trailingText: age, isSearchSelected: false, onTap: {})
    }
}
