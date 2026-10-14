import Foundation

/// Decides whether a working agent that just stopped deserves a "finished" toast, and what it says.
public enum LongTaskRule {
    public struct Decision: Equatable, Sendable {
        public let announce: Bool
        /// "finished after 12m" style line, `nil` when there is nothing to add.
        public let detail: String?
    }

    /// Floor for a local agent's working to idle flip when the threshold is 0: those flips happen on every
    /// turn, so announcing all of them would be noise.
    public static let localNoiseFloor: TimeInterval = 60

    /// - Parameters:
    ///   - workedFor: How long the agent was `working` before it stopped.
    ///   - thresholdMinutes: The user's setting. `0` means "no duration line; local floor only".
    ///   - landedOnDone: `true` when herdr reported `done`; `false` for the idle landing that local agents
    ///     (which never report `done`) and herdr's sticky path use.
    ///   - isLocal: Whether the agent came from the local source.
    ///
    /// herdr's `done` is an explicit statement and always toasts, as it did before this rule existed; the
    /// threshold only adds the duration line. A local idle landing is the only finish signal a local agent
    /// has, so the threshold gates whether it toasts at all. herdr's idle landing never toasts.
    public static func evaluate(
        workedFor: TimeInterval, thresholdMinutes: Int, landedOnDone: Bool, isLocal: Bool
    ) -> Decision {
        let timed = Decision(announce: true, detail: "finished after \(format(workedFor))")
        let threshold = thresholdMinutes > 0 ? Double(thresholdMinutes) * 60 : localNoiseFloor
        let isLong = workedFor >= threshold
        if landedOnDone {
            return isLong && thresholdMinutes > 0 ? timed : Decision(announce: true, detail: nil)
        }
        return isLocal && isLong ? timed : Decision(announce: false, detail: nil)
    }

    /// `45s`, `12m`, `1h`, `1h 5m`. Whole minutes truncate; under a minute reads in seconds.
    public static func format(_ seconds: TimeInterval) -> String {
        ShortDuration.format(seconds: seconds, dropsZeroMinutes: true)
    }
}
