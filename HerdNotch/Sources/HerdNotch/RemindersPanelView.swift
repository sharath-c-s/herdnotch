import AppKit
import HerdPanelUI
import NotchCore
import NotchGeometry
import SwiftUI

/// Due-date chip text, shared by the System page card and the full reminders view.
enum ReminderDueText {
    private static let time = formatter("jmm")
    private static let weekday = formatter("EEE")
    private static let date = formatter("MMMd")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func daysAway(_ due: Date, now: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)
        ).day ?? 0
    }

    /// `5:00 PM` today, `Tue` within the next 6 days, `Sep 4` otherwise.
    static func chip(_ due: Date, now: Date) -> String {
        if Calendar.current.isDateInToday(due) { return time.string(from: due) }
        let days = daysAway(due, now: now)
        return days > 0 && days < 7 ? weekday.string(from: due) : date.string(from: due)
    }

    /// Compose preview: day and time (`Today 17:00`, `Sep 4 17:00`); day only when the text named no time.
    static func composeChip(_ due: Date, now: Date, hasTime: Bool = true) -> String {
        let days = daysAway(due, now: now)
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        case 2..<7: day = weekday.string(from: due)
        default: day = date.string(from: due)
        }
        return hasTime ? "\(day) \(time.string(from: due))" : day
    }
}

/// The one reminder row: completion circle, title, due chip (overdue in `blocked`).
struct ReminderRowView: View {
    let item: RemindersService.ReminderItem
    let palette: HerdPalette
    let now: Date
    let onComplete: (RemindersService.ReminderItem) -> Void

    @State private var isCompleting = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: complete) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                        .opacity(isCompleting ? 0 : 1)
                    Circle()
                        .fill(palette.done)
                        .opacity(isCompleting ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .opacity(isCompleting ? 1 : 0)
                }
                .frame(width: 14, height: 14)
                // Visual circle stays 14x14; the padded 22x22 hit target fixed "ticking doesn't always complete it".
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            .accessibilityLabel("Complete")
            .accessibilityHint("Marks \"\(item.title)\" as done.")

            Group {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .strikethrough(isCompleting, color: palette.textPrimary.opacity(0.5))
                    .opacity(isCompleting ? 0.5 : 1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let dueDate = item.dueDate {
                    Text(ReminderDueText.chip(dueDate, now: now))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dueDate < now ? palette.blocked : palette.textTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                item.dueDate.map { "\(item.title), due \(ReminderDueText.chip($0, now: now))" } ?? item.title
            )
        }
        .frame(height: 26)
    }

    /// Fills and strikes immediately, then waits 400ms before `onComplete` removes the row.
    private func complete() {
        guard !isCompleting else { return }
        isCompleting = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            onComplete(item)
            isCompleting = false
        }
    }
}

/// Every incomplete reminder in a vertical scroller, one `ReminderRowView` each.
struct ReminderListView: View {
    let items: [RemindersService.ReminderItem]
    let palette: HerdPalette
    let now: Date
    let onComplete: (RemindersService.ReminderItem) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    // Stable identity keeps a row's completion state bound to its reminder through a reflow.
                    ReminderRowView(item: item, palette: palette, now: now, onComplete: onComplete)
                        .id(item.id)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: items)
    }
}

/// The `notDetermined` (grant) and `denied` (open System Settings) states.
struct ReminderAccessPromptView: View {
    let state: RemindersService.AuthorizationState
    let palette: HerdPalette
    let onRequestAccess: () -> Void

    @State private var isSettingsLinkHovering = false

    var body: some View {
        Group {
            if state == .denied {
                VStack(spacing: 6) {
                    Text("Reminders access is off")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Button(action: openPrivacySettings) {
                        Text("Open Settings…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSettingsLinkHovering ? palette.textSecondary : palette.textTertiary)
                            .underline(isSettingsLinkHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { isSettingsLinkHovering = $0 }
                }
            } else {
                VStack(spacing: 8) {
                    Text("Herd needs access to Reminders")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onRequestAccess) {
                        Text("Grant Access")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The authorized-and-empty state: everything is done.
struct ReminderEmptyStateView: View {
    let palette: HerdPalette

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(palette.done.opacity(0.8))
            Text("All clear")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The full-panel reminders view: header, compose field with a live due-time chip, and the full list.
/// Takes plain values (no EventKit service) so the preview dump can inject sample items.
struct RemindersPanelView: View {
    let palette: HerdPalette
    let mode: ReminderMode
    let items: [RemindersService.ReminderItem]
    let authorizationState: RemindersService.AuthorizationState
    let now: Date
    let returnsToPage: Bool
    let onAdd: (ReminderDraft) -> Void
    let onComplete: (RemindersService.ReminderItem) -> Void
    let onRequestAccess: () -> Void
    /// Collapses the notch.
    let onEscape: () -> Void
    /// Returns to the System page (only used when `returnsToPage`).
    let onBack: () -> Void
    /// Bumped by the host on a hotkey open that lands while this view is already mounted.
    let focusToken: Int
    /// Asks the host to hold or release the panel open (see `InteractionLock.textEntry`). Idempotent on the host.
    let onTextEntry: (Bool) -> Void
    /// Bumped by the host when it released the hold because focus was lost; drops field focus.
    let blurToken: Int

    @State private var text: String
    @State private var draft: ReminderDraft?
    @State private var chip: String?
    @FocusState private var fieldFocused: Bool

    init(
        palette: HerdPalette, mode: ReminderMode, items: [RemindersService.ReminderItem],
        authorizationState: RemindersService.AuthorizationState, now: Date, returnsToPage: Bool,
        initialText: String = "", focusToken: Int = 0, blurToken: Int = 0, onTextEntry: @escaping (Bool) -> Void = { _ in },
        onAdd: @escaping (ReminderDraft) -> Void,
        onComplete: @escaping (RemindersService.ReminderItem) -> Void,
        onRequestAccess: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        self.palette = palette
        self.mode = mode
        self.items = items
        self.authorizationState = authorizationState
        self.now = now
        self.returnsToPage = returnsToPage
        self.onAdd = onAdd
        self.onComplete = onComplete
        self.onRequestAccess = onRequestAccess
        self.onEscape = onEscape
        self.onBack = onBack
        self.focusToken = focusToken
        self.onTextEntry = onTextEntry
        self.blurToken = blurToken
        _text = State(initialValue: initialText)
        let initial = initialText.isEmpty ? nil : ReminderDraft.parse(initialText, now: Date())
        _draft = State(initialValue: initial)
        _chip = State(initialValue: Self.chipText(for: initial))
    }

    /// The cards area: from the cards' top to the shelf's top, across the full inner width.
    static func frame(in layout: BentoLayout) -> CGRect {
        CGRect(
            x: layout.agents.minX, y: layout.agents.minY,
            width: layout.usage.maxX - layout.agents.minX, height: layout.agents.height)
    }

    private static func chipText(for draft: ReminderDraft?) -> String? {
        guard let due = draft?.due else { return nil }
        return ReminderDueText.composeChip(due, now: Date(), hasTime: draft?.hasTime ?? true)
    }

    private func updateDraft() {
        draft = text.isEmpty ? nil : ReminderDraft.parse(text, now: Date())
        chip = Self.chipText(for: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch authorizationState {
            case .notDetermined, .denied:
                ReminderAccessPromptView(state: authorizationState, palette: palette, onRequestAccess: onRequestAccess)
            case .authorized:
                composeField
                if let chip {
                    HStack(spacing: 4) {
                        Image(systemName: draft?.hasTime == false ? "calendar" : "alarm.fill")
                            .accessibilityHidden(true)
                        Text(chip)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Due \(chip)")
                }
                if items.isEmpty {
                    ReminderEmptyStateView(palette: palette)
                } else {
                    ReminderListView(items: items, palette: palette, now: now, onComplete: onComplete)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if mode == .compose { focusField() } }
        .onChange(of: text) { old, new in
            updateDraft()
            // Typing after a mouse return (hold was released on focus loss) re-acquires it.
            if old.isEmpty, !new.isEmpty, fieldFocused { onTextEntry(true) }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .compose {
                focusField()
            } else {
                fieldFocused = false
            }
        }
        .onChange(of: blurToken) { _, _ in fieldFocused = false }
        .onDisappear { onTextEntry(false) }
        .onChange(of: focusToken) { _, _ in
            if mode == .compose { focusField() }
        }
    }

    private var header: some View {
        HStack {
            Text("REMINDERS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            if authorizationState == .authorized {
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(height: 16)
    }

    private var composeField: some View {
        TextField("New reminder, e.g. call bank 5pm", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(palette.textPrimary)
            .tint(palette.done)
            .focused($fieldFocused)
            .onSubmit(submit)
            .onExitCommand {
                switch ReminderEscape.action(text: text, returnsToPage: returnsToPage) {
                case .clearText: text = ""
                case .backToPage: onBack()
                case .collapse: onEscape()
                }
            }
            .accessibilityLabel("New reminder")
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Same retry as `enterSearchMode`: the first assignment can land before the field exists in the window.
    private func focusField() {
        fieldFocused = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func submit() {
        let draft = ReminderDraft.parse(text, now: Date())
        guard !draft.title.isEmpty else { return }
        onAdd(draft)
        text = ""
        if mode == .compose {
            onTextEntry(false)
            onEscape()
        }
    }
}
