import AppKit
import HerdPanelUI
import NotchCore
import SwiftUI

/// The file shelf's content: header, horizontal tile strip, or an empty-state hint. The card frame and
/// the drop target live in `NotchContentView`; this view only draws and routes tile actions.
struct ShelfStripView: View {
    @ObservedObject var service: ShelfService
    let palette: HerdPalette
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if service.items.isEmpty {
                Text("Drop files here")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(service.items.sorted { $0.addedAt > $1.addedAt }) { item in
                            ShelfTile(
                                item: item, fileURL: service.fileURL(for: item), palette: palette,
                                onOpen: { service.open(item) },
                                onMissing: { service.prune() },
                                onRemove: { service.remove(item.id) },
                                onDragBegan: {
                                    service.dragBegan(item.id)
                                    onDragBegan()
                                },
                                onDragEnded: {
                                    service.dragEnded(item.id)
                                    onDragEnded()
                                })
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SHELF")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.textSecondary)
            if !service.items.isEmpty {
                Text("\(service.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: 8)
            if !service.items.isEmpty {
                Button("Clear") { service.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityLabel("Clear shelf")
            }
        }
        .frame(height: 14)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let fileURL: URL
    let palette: HerdPalette
    let onOpen: () -> Void
    let onMissing: () -> Void
    let onRemove: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    /// Computed once per tile on appear, not per render.
    @State private var icon: NSImage?

    /// A copy, so resizing never mutates `NSWorkspace`'s shared cached image.
    private static func makeIcon(forFile path: String) -> NSImage {
        let image = (NSWorkspace.shared.icon(forFile: path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 36, height: 36)
        return image
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 36, height: 36)
                Text(item.fileName)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 84, alignment: .leading)
            }
            .padding(4)
            .background(Color.white.opacity(isHovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                ShelfTileDragSource(
                    fileURL: fileURL, icon: icon,
                    onOpen: onOpen, onMissing: onMissing,
                    onDragBegan: onDragBegan, onDragEnded: onDragEnded)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.fileName), shelf file")
            .accessibilityHint("Double click to open. Drag to copy it elsewhere.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Remove from shelf") { onRemove() }

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(2)
                .accessibilityLabel("Remove \(item.fileName) from shelf")
            }
        }
        .onHover { isHovering = $0 }
        .onAppear {
            if icon == nil { icon = Self.makeIcon(forFile: fileURL.path) }
        }
        .accessibilityElement(children: .contain)
    }
}
