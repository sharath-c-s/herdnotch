import Foundation

/// One file or folder copied onto the notch shelf.
public struct ShelfItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fileName: String
    /// Path under the shelf cache root, `<uuid>/<fileName>` (see ``Shelf/cacheRelativePath(id:fileName:)``).
    public let relativePath: String
    public let addedAt: Date
    public let byteSize: Int64
    /// Original location, used only to detect a re-drop of the same unchanged file.
    public let sourcePath: String
    public let sourceModified: Date

    public init(
        id: UUID, fileName: String, relativePath: String, addedAt: Date, byteSize: Int64,
        sourcePath: String, sourceModified: Date
    ) {
        self.id = id
        self.fileName = fileName
        self.relativePath = relativePath
        self.addedAt = addedAt
        self.byteSize = byteSize
        self.sourcePath = sourcePath
        self.sourceModified = sourceModified
    }
}

/// Pure shelf policy: expiry, cache layout, duplicate replacement and the per-drop size cap.
public enum Shelf {
    /// Items older than this are purged.
    public static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// Largest total size accepted for a single drop, in bytes (500 MB).
    public static let maxDropBytes: Int64 = 500 * 1_000_000

    /// Items whose age is at least `ttl` at `now`.
    public static func expired(_ items: [ShelfItem], now: Date, ttl: TimeInterval = defaultTTL) -> [ShelfItem] {
        items.filter { now.timeIntervalSince($0.addedAt) >= ttl }
    }

    /// `<uuid>/<name>`: each item gets its own folder so the cached file keeps its real name when dragged out.
    public static func cacheRelativePath(id: UUID, fileName: String) -> String {
        "\(id.uuidString)/\(fileName)"
    }

    /// Whether a drop totalling `sizes` bytes is accepted. Sums in a saturating way so overflow cannot
    /// sneak a huge drop under the cap.
    public static func isDropAllowed(sizes: [Int64], cap: Int64 = maxDropBytes) -> Bool {
        var total: Int64 = 0
        for size in sizes {
            let (sum, overflow) = total.addingReportingOverflow(max(0, size))
            if overflow { return false }
            total = sum
        }
        return total <= cap
    }

    /// Adds `new` to `items`; an existing item with the same source path and modification date is replaced.
    /// - Returns: the new list and the replaced items, whose cache folders the caller must delete.
    public static func inserting(_ new: ShelfItem, into items: [ShelfItem]) -> (items: [ShelfItem], replaced: [ShelfItem]) {
        let replaced =
            new.sourcePath.isEmpty
            ? [] : items.filter { $0.sourcePath == new.sourcePath && $0.sourceModified == new.sourceModified }
        let kept = items.filter { item in !replaced.contains { $0.id == item.id } }
        return (kept + [new], replaced)
    }

    /// Encodes the index. Dates use `secondsSince1970` so sub-second precision survives a relaunch and the
    /// duplicate rule in ``inserting(_:into:)`` still matches.
    public static func encodeIndex(_ items: [ShelfItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(items)
    }

    /// Decodes the index row by row so one bad row drops only itself.
    /// - Returns: `nil` when `data` is not a JSON array at all, else the good rows and the dropped count.
    public static func decodeIndex(_ data: Data) -> (items: [ShelfItem], dropped: Int)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let rows = try? decoder.decode([LossyRow].self, from: data) else { return nil }
        let items = rows.compactMap(\.item)
        return (items, rows.count - items.count)
    }

    /// One cache folder as found on disk, for ``rebuilt(from:knownIDs:)``.
    public struct FolderListing: Sendable, Equatable {
        public let name: String
        public let entries: [String]
        public let created: Date
        public let byteSize: Int64

        public init(name: String, entries: [String], created: Date, byteSize: Int64) {
            self.name = name
            self.entries = entries
            self.created = created
            self.byteSize = byteSize
        }
    }

    /// Items recovered from cache folders whose id is not in `knownIDs`: one per `<uuid>/` folder holding
    /// exactly one entry. Source fields stay empty so a recovered item never dedupes.
    public static func rebuilt(from folders: [FolderListing], knownIDs: Set<UUID> = []) -> [ShelfItem] {
        folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.name), !knownIDs.contains(id), folder.entries.count == 1,
                let fileName = folder.entries.first
            else { return nil }
            return ShelfItem(
                id: id, fileName: fileName, relativePath: cacheRelativePath(id: id, fileName: fileName),
                addedAt: folder.created, byteSize: folder.byteSize, sourcePath: "",
                sourceModified: .distantPast)
        }
    }

    private struct LossyRow: Decodable {
        let item: ShelfItem?
        init(from decoder: any Decoder) throws { item = try? ShelfItem(from: decoder) }
    }
}
