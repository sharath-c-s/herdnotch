import HerdPanelUI
import NotchCore
import SwiftUI

/// Clock over date, the left of the utility band. Standalone so the preview dump renders the real thing.
struct BandClockView: View {
    let clock: String
    let date: String
    let palette: HerdPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(clock)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
            Text(date)
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// `Herd  System  Health` with an underline on the current page. Plain buttons, no animation; the owner
/// decides what a click or a hover dwell does.
struct PageSwitcherView: View {
    let selected: NotchPage
    let palette: HerdPalette
    let onSelect: (NotchPage) -> Void
    let onHover: (NotchPage, Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            tab("Herd", page: .herd)
            tab("System", page: .system)
            tab("Health", page: .health)
        }
    }

    private func tab(_ title: String, page: NotchPage) -> some View {
        let isSelected = selected == page
        return Button(action: { onSelect(page) }) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                    .lineLimit(1)
                // Always laid out so selecting a page never shifts the text.
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? palette.textPrimary : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onHover(page, $0) }
        .help("Hover or click to show \(title)")
        .accessibilityLabel("\(title) page")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
