import Foundation

/// Refuses a second send against a pane screen that has not redrawn since the last send.
public enum PaneSendGuard {
    /// False when `fresh` is the same screen revision the previous successful send was based on.
    public static func allows(freshRevision: UInt64, lastSentRevision: UInt64?) -> Bool {
        freshRevision != lastSentRevision
    }
}
