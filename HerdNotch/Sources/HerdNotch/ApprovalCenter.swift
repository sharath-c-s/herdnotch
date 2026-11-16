import Combine
import Foundation
import HerdHost
import HerdKit

/// Owns the approval socket and the book of hook requests waiting for a decision.
///
/// Every request ends in exactly one reply: a decision, or passthrough (empty output, so Claude shows its
/// own dialog). A failure to start leaves the feature off and the hook falls back to passthrough.
@MainActor
final class ApprovalCenter: ObservableObject {
    /// Mirror of the book, keyed by Claude session ID.
    @Published private(set) var pending: [String: PendingApproval] = [:]

    private var book = ApprovalBook()
    /// Wrapped-input lines per token, so a render never reshapes a large request.
    private var hookLineCache: [UInt64: [String]] = [:]
    private let server: ApprovalSocketServer
    private let preferences: HerdPreferences

    init(preferences: HerdPreferences) {
        self.preferences = preferences
        self.server = ApprovalSocketServer(path: PermissionHookClient.defaultSocketPath)
    }

    func start() {
        do {
            try server.start(
                onRequest: { [weak self] token, request in
                    Task { @MainActor in self?.received(token: token, request: request) }
                },
                onClose: { [weak self] token in
                    Task { @MainActor in self?.closed(token: token) }
                })
        } catch {
            // The error text carries paths only, never request contents. It also covers a second instance backing off.
            FileHandle.standardError.write(Data("herdnotch: approvals disabled: \(error)\n".utf8))
        }
    }

    func stop() {
        server.stop()
        book = ApprovalBook()
        publish()
    }

    /// Answers the request the user was shown. A token that was superseded or swept is a no-op, never another request.
    ///
    /// - Returns: Whether a reply was sent.
    @discardableResult
    func decide(token: UInt64, _ decision: HookDecision) -> Bool {
        guard let entry = book.resolve(token: token) else { return false }
        server.reply(token: token, output: HookOutput.render(decision, for: entry.request))
        publish()
        return true
    }

    /// Full input lines of the request, computed once per token.
    func hookLines(for approval: PendingApproval) -> [String] {
        if let cached = hookLineCache[approval.token] { return cached }
        let input = approval.request.toolInput.asAny as? [String: Any] ?? [:]
        let lines = PreviewText.hookLines(toolName: approval.request.toolName, input: input)
        hookLineCache[approval.token] = lines
        return lines
    }

    /// Releases entries that will never get a UI decision; slice C calls this from the herd poll.
    func sweep(now: Date, knownSessionIDs: Set<String>, blockedSessionIDs: Set<String>) {
        let released = book.sweep(now: now, knownSessionIDs: knownSessionIDs, blockedSessionIDs: blockedSessionIDs)
        for token in released { server.reply(token: token, output: Data()) }
        publish()
    }

    private func received(token: UInt64, request: HookRequest) {
        // Answered here, not in the herd sweep, which does not run while herd watching is off.
        guard preferences.isEnabled, preferences.notchApprovalsEnabled else {
            server.reply(token: token, output: Data())
            return
        }
        for superseded in book.add(request, token: token, now: Date()) {
            server.reply(token: superseded, output: Data())
        }
        publish()
    }

    private func closed(token: UInt64) {
        book.drop(token: token)
        publish()
    }

    private func publish() {
        let next = Dictionary(book.all.map { ($0.request.sessionID, $0) }, uniquingKeysWith: { _, latest in latest })
        hookLineCache = hookLineCache.filter { token, _ in book.all.contains { $0.token == token } }
        if next != pending { pending = next }
    }
}
