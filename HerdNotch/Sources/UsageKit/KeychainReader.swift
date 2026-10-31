import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

/// Keychain services whose read failed after a prompt-length wait, remembered for the process lifetime.
final class KeychainDenials: @unchecked Sendable {
    private let lock = NSLock()
    private var services: Set<String> = []

    func contains(_ service: String) -> Bool { lock.withLock { services.contains(service) } }
    func insert(_ service: String) { lock.withLock { _ = services.insert(service) } }
}

/// Reads still waiting on `security`, so a second caller for the same item shares the first one's answer
/// instead of stacking a second Keychain prompt on top of it.
final class KeychainReads: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: Task<String?, Never>] = [:]

    func run(key: String, _ work: @escaping @Sendable () async -> String?) async -> String? {
        let task = lock.withLock { () -> Task<String?, Never> in
            if let running = pending[key] { return running }
            // Unstructured: an abandoned caller must not cancel the read a later caller is about to join.
            let created = Task { await work() }
            pending[key] = created
            return created
        }
        let answer = await task.value
        lock.withLock { if pending[key] == task { pending[key] = nil } }
        return answer
    }
}

/// Read-only Keychain access through `/usr/bin/security`, the same accessor Claude Code and Antigravity
/// save through, so a user's "Always Allow" applies. There is deliberately no write path.
struct KeychainReader: Sendable {
    var runner: any ProcessRunner
    var denials = KeychainDenials()
    var reads = KeychainReads()
    /// A failure slower than this (and not "item not found") is taken to be a denied or dismissed prompt.
    var promptThreshold: TimeInterval = 1

    /// Long enough for a user to answer an access prompt (as OpenUsage does); ending the process closes it.
    /// `security` exits 44 (errSecItemNotFound) for a missing item, however long it took.
    static let itemNotFoundStatus: Int32 = 44

    static let timeout: TimeInterval = 600

    /// The secret text, or nil when the item is missing, access is denied or the tool fails.
    ///
    /// A denied service is not asked again until the app restarts, so one item prompts at most once a session.
    func read(service: String, account: String? = nil) async -> String? {
        if denials.contains(service) { return nil }
        let reader = self
        return await reads.run(key: "\(service)\u{0}\(account ?? "")") { await reader.spawn(service: service, account: account) }
    }

    private func spawn(service: String, account: String?) async -> String? {
        if denials.contains(service) { return nil }
        let arguments = ["find-generic-password"] + (account.map { ["-a", $0] } ?? []) + ["-s", service, "-w"]
        let started = Date()
        let result = try? await runner.run(executable: "/usr/bin/security", arguments: arguments, timeout: Self.timeout)
        guard let result, result.succeeded else {
            let missing = result?.status == Self.itemNotFoundStatus
            if !missing, Date().timeIntervalSince(started) >= promptThreshold { denials.insert(service) }
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
