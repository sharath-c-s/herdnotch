import Foundation

/// What survives a relaunch: percentages, resets, plan names and timestamps. Never a token, and no cooldown:
/// a relaunch always fetches.
struct PersistedUsage: Codable, Equatable, Sendable {
    /// Keyed by `UsageProvider.rawValue` so the JSON is an object, not an alternating array.
    var snapshots: [String: UsageSnapshot] = [:]
}

/// JSON cache of `PersistedUsage`. Failures are swallowed: the cache is an optimization, never a dependency.
struct UsageStore: Sendable {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/HerdNotch/usage.json")
    }

    func load() -> PersistedUsage {
        guard let data = try? Data(contentsOf: url) else { return PersistedUsage() }
        guard let decoded = try? JSONDecoder().decode(PersistedUsage.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return PersistedUsage()
        }
        return decoded
    }

    func save(_ value: PersistedUsage) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
