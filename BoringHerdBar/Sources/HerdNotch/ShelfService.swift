import AppKit
import Foundation
import NotchCore

/// What a drop did: the shelf contents afterwards plus anything the user must hear about.
struct ShelfSnapshot: Sendable {
    /// Monotonic per store; the service ignores a snapshot older than the last one it applied.
    let sequence: UInt64
    let items: [ShelfItem]
    /// A user-facing message when part or all of the operation failed, else `nil`.
    let message: String?
}

/// Owns the shelf's on-disk cache and `items.json`. An actor so every file operation runs off the main
/// thread and operations are serialised (a purge can never interleave with a copy).
private actor ShelfStore {
    private let root: URL
    private var items: [ShelfItem] = []
    private var sequence: UInt64 = 0
    private let fileManager = FileManager.default
    private var isLoaded = false

    init(root: URL) {
        self.root = root
    }

    private var indexURL: URL { root.appendingPathComponent("items.json") }

    /// Loads the index once; every other operation calls this first, so an early `add` cannot be
    /// overwritten by (or overwrite) the persisted index.
    private func ensureLoaded(now: Date) {
        guard !isLoaded else { return }
        isLoaded = true
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var recovered = false
        if fileManager.fileExists(atPath: indexURL.path) {
            if let data = try? Data(contentsOf: indexURL), let decoded = Shelf.decodeIndex(data) {
                items = decoded.items
                recovered = decoded.dropped > 0
            } else {
                recovered = true
            }
            if recovered { quarantineIndex() }
        }
        if recovered {
            // Unreadable index: keep every cache folder and rebuild from them instead of orphan removal.
            let rebuilt = Shelf.rebuilt(from: folderListings(), knownIDs: Set(items.map(\.id)))
            items += rebuilt
        } else {
            removeOrphans()
        }
        pruneMissing()
        purgeExpired(now: now, skipping: [])
        if !(recovered && items.isEmpty) { persist() }
    }

    func load(now: Date) -> ShelfSnapshot {
        ensureLoaded(now: now)
        return snapshot(message: nil)
    }

    func purge(now: Date, skipping: Set<UUID>) -> ShelfSnapshot {
        ensureLoaded(now: now)
        pruneMissing()
        purgeExpired(now: now, skipping: skipping)
        persist()
        return snapshot(message: nil)
    }

    /// Drops items whose cached file has vanished (macOS may purge the caches directory).
    func prune() -> ShelfSnapshot {
        ensureLoaded(now: Date())
        pruneMissing()
        persist()
        return snapshot(message: nil)
    }

    func remove(id: UUID) -> ShelfSnapshot {
        ensureLoaded(now: Date())
        if let item = items.first(where: { $0.id == id }) { delete(item) }
        items.removeAll { $0.id == id }
        persist()
        return snapshot(message: nil)
    }

    func clear() -> ShelfSnapshot {
        ensureLoaded(now: Date())
        items.forEach(delete)
        items = []
        persist()
        return snapshot(message: nil)
    }

    func add(urls: [URL], now: Date) -> ShelfSnapshot {
        ensureLoaded(now: now)
        // Skip tiles dragged back onto the panel; resolve symlinks so we size and copy the real file.
        let cachePrefix = root.resolvingSymlinksInPath().path + "/"
        let sources = urls.map { (original: $0, resolved: $0.resolvingSymlinksInPath()) }
            .filter { !$0.resolved.path.hasPrefix(cachePrefix) }
        guard !sources.isEmpty else { return snapshot(message: nil) }
        let sizes = sources.map { Self.byteSize(of: $0.resolved) }
        guard Shelf.isDropAllowed(sizes: sizes) else {
            return snapshot(message: "Shelf: drop is over 500 MB")
        }
        var failed: [String] = []
        for (source, size) in zip(sources, sizes) {
            let url = source.original
            let id = UUID()
            let name = url.lastPathComponent
            let relative = Shelf.cacheRelativePath(id: id, fileName: name)
            let folder = root.appendingPathComponent(id.uuidString)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source.resolved, to: root.appendingPathComponent(relative))
            } catch {
                try? fileManager.removeItem(at: folder)
                failed.append(name)
                continue
            }
            let modified = (try? source.resolved.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let item = ShelfItem(
                id: id, fileName: name, relativePath: relative, addedAt: now, byteSize: size,
                sourcePath: url.path, sourceModified: modified)
            let result = Shelf.inserting(item, into: items)
            result.replaced.forEach(delete)
            items = result.items
        }
        persist()
        let message = failed.isEmpty ? nil : "Shelf: could not copy \(failed.joined(separator: ", "))"
        return snapshot(message: message)
    }

    private func snapshot(message: String?) -> ShelfSnapshot {
        sequence += 1
        return ShelfSnapshot(sequence: sequence, items: items, message: message)
    }

    private func purgeExpired(now: Date, skipping: Set<UUID>) {
        let expired = Shelf.expired(items, now: now).filter { !skipping.contains($0.id) }
        guard !expired.isEmpty else { return }
        expired.forEach(delete)
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
    }

    private func removeOrphans() {
        let known = Set(items.map { $0.id.uuidString })
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children where !child.lastPathComponent.hasPrefix("items.json") && !known.contains(child.lastPathComponent) {
            try? fileManager.removeItem(at: child)
        }
    }

    private func pruneMissing() {
        let missing = items.filter { !fileManager.fileExists(atPath: root.appendingPathComponent($0.relativePath).path) }
        guard !missing.isEmpty else { return }
        missing.forEach(delete)
        let ids = Set(missing.map(\.id))
        items.removeAll { ids.contains($0.id) }
    }

    /// Moves an unreadable index to `items.json.bad`, replacing any older one.
    private func quarantineIndex() {
        let bad = root.appendingPathComponent("items.json.bad")
        try? fileManager.removeItem(at: bad)
        try? fileManager.moveItem(at: indexURL, to: bad)
    }

    private func folderListings() -> [Shelf.FolderListing] {
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        return children.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let entries = try? fileManager.contentsOfDirectory(atPath: folder.path)
            else { return nil }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let size = entries.reduce(Int64(0)) { $0 + Self.byteSize(of: folder.appendingPathComponent($1)) }
            return Shelf.FolderListing(name: folder.lastPathComponent, entries: entries, created: created, byteSize: size)
        }
    }

    private func delete(_ item: ShelfItem) {
        try? fileManager.removeItem(at: root.appendingPathComponent(item.id.uuidString))
    }

    private func persist() {
        guard let data = try? Shelf.encodeIndex(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Size of a file, or the recursive sum of regular files in a folder.
    private static func byteSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let child = enumerator?.nextObject() as? URL {
            if let size = (try? child.resourceValues(forKeys: keys))?.fileSize { total += Int64(size) }
        }
        return total
    }
}

/// The notch's temporary file shelf: copies dropped files into `~/Library/Caches/HerdNotch/Shelf` so they
/// can be dragged out again, and expires them after 24 hours.
///
/// Thread-safety: `@MainActor` for published state; every file operation runs in ``ShelfStore`` off the
/// main thread, and results are applied only if newer than the last applied snapshot.
@MainActor
final class ShelfService: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    /// Called with a user-facing message when a drop is rejected or a copy fails.
    var onMessage: ((String) -> Void)?

    private let root: URL
    private let store: ShelfStore
    private var appliedSequence: UInt64 = 0
    private var purgeTimer: DispatchSourceTimer?
    /// Items currently being dragged out; the timer purge skips them until the drag ends.
    private var draggingIDs: Set<UUID> = []

    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdNotch/Shelf", isDirectory: true)
        store = ShelfStore(root: root)
    }

    deinit {
        purgeTimer?.cancel()
    }

    /// Loads the persisted shelf, purges expired items and orphans, and arms the 10-minute purge.
    func start() {
        guard purgeTimer == nil else { return }
        Task { apply(await store.load(now: Date())) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 600, repeating: 600)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply(await self.store.purge(now: Date(), skipping: self.draggingIDs))
            }
        }
        purgeTimer = timer
        timer.resume()
    }

    /// Copies `urls` onto the shelf. Over-cap drops copy nothing and report via ``onMessage``.
    func add(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        Task { apply(await store.add(urls: files, now: Date())) }
    }

    func dragBegan(_ id: UUID) {
        draggingIDs.insert(id)
    }

    func dragEnded(_ id: UUID) {
        draggingIDs.remove(id)
    }

    /// Drops items whose cached file no longer exists, e.g. after the system purged the caches directory.
    func prune() {
        Task { apply(await store.prune()) }
    }

    /// Opens the cached copy, or prunes the item if the file has vanished.
    func open(_ item: ShelfItem) {
        let url = fileURL(for: item)
        Task {
            let snapshot = await store.prune()
            apply(snapshot)
            if snapshot.items.contains(where: { $0.id == item.id }) { NSWorkspace.shared.open(url) }
        }
    }

    func remove(_ id: UUID) {
        Task { apply(await store.remove(id: id)) }
    }

    func clear() {
        Task { apply(await store.clear()) }
    }

    /// The cached copy's location, for opening or dragging out.
    func fileURL(for item: ShelfItem) -> URL {
        root.appendingPathComponent(item.relativePath)
    }

    private func apply(_ snapshot: ShelfSnapshot) {
        if let message = snapshot.message { onMessage?(message) }
        guard snapshot.sequence > appliedSequence else { return }
        appliedSequence = snapshot.sequence
        items = snapshot.items
    }
}
