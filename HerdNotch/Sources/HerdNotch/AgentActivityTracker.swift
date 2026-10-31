import Foundation
import HerdKit

/// Owns the per-transcript readers for the notch's agent rows and runs all transcript IO on its own
/// serial queue, so the main actor never touches the disk.
final class AgentActivityTracker: @unchecked Sendable {
    // Safety of @unchecked: `readers` and `locator` are only touched on `queue`, through `queue.async`
    // blocks and the `queue.sync` in `pendingAsk`.
    private let queue = DispatchQueue(label: "com.herdnotch.activity", qos: .utility)
    private var readers: [String: TranscriptReader] = [:]
    private let locator = TranscriptLocator()

    /// The transcript session id for an agent whose transcript is readable here, else `nil`.
    static func transcriptID(session: HerdSession, agent: HerdAgent) -> String? {
        guard !session.isRemote, let id = agent.agentSessionID, !id.isEmpty else { return nil }
        // Local Claude agents carry their registry session id; local Codex agents have none and stay skipped.
        if agent.source == .local { return agent.agent == "claude" ? id : nil }
        let claude = agent.agent == "claude" || (agent.agentSessionSource?.contains("claude") ?? false)
        return claude ? id : nil
    }

    /// The pending permission or question text for `id`, `nil` when none or the transcript is not found.
    ///
    /// Shares the readers ``activities(wanted:alive:)`` uses, so a transcript is tailed once however many
    /// callers ask. Blocks on the tracker's queue, so call it off the main actor (the snapshot queue does).
    func pendingAsk(for id: String) -> String? {
        queue.sync { reader(for: id)?.read().pendingAsk }
    }

    /// Must run on ``queue``.
    private func reader(for id: String) -> TranscriptReader? {
        if let existing = readers[id] { return existing }
        guard let url = locator.locate(id) else { return nil }
        let reader = TranscriptReader(url: url)
        readers[id] = reader
        return reader
    }

    /// Reads fresh activity for `wanted` ids and drops readers for ids not in `alive`.
    ///
    /// - Returns: Activity keyed by id. Ids whose transcript cannot be found are absent.
    func activities(wanted: Set<String>, alive: Set<String>) async -> [String: AgentActivity] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                readers = readers.filter { alive.contains($0.key) }
                var result: [String: AgentActivity] = [:]
                for id in wanted {
                    guard let reader = reader(for: id) else { continue }
                    var activity = reader.read()
                    activity.runningSubagents = SubagentCounter.count(in: TranscriptLocator.subagentsDir(for: reader.url))
                    result[id] = activity
                }
                continuation.resume(returning: result)
            }
        }
    }
}
