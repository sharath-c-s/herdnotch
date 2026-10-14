import AppKit
import SwiftUI

/// Transparent overlay for one shelf tile that starts a real AppKit drag session with the cached file.
///
/// SwiftUI `.onDrag` has no end callback, so it cannot hold the reducer's `.drag` lock for the whole
/// session; owning the session here lets `onDragBegan`/`onDragEnded` bracket it exactly. Also reports
/// double-clicks, since this view sits above the tile and would otherwise swallow them.
struct ShelfTileDragSource: NSViewRepresentable {
    let fileURL: URL
    let icon: NSImage?
    let onOpen: () -> Void
    let onMissing: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.setAccessibilityElement(false)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.fileURL = fileURL
        view.icon = icon
        view.onOpen = onOpen
        view.onMissing = onMissing
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var fileURL: URL?
        var icon: NSImage?
        var onOpen: (() -> Void)?
        var onMissing: (() -> Void)?
        var onDragBegan: (() -> Void)?
        var onDragEnded: (() -> Void)?

        private var mouseDownPoint: NSPoint?
        private var sessionStarted = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            sessionStarted = false
            if event.clickCount == 2 { onOpen?() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !sessionStarted, let start = mouseDownPoint, let fileURL else { return }
            let point = event.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            sessionStarted = true
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                onMissing?()
                return
            }
            let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            // Icon-sized frame at the tile's leading padding, so the drag image is not stretched.
            item.setDraggingFrame(NSRect(x: 4, y: (bounds.height - 36) / 2, width: 36, height: 36), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        /// The lock is taken only once AppKit has actually started the session, so it always gets released
        /// by `endedAt`.
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            onDragBegan?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDragEnded?()
        }
    }
}
