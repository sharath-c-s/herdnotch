import Dispatch
import Foundation

/// A single point in time by which a whole operation must finish.
///
/// Exists because a per-phase timeout is not a budget. Giving connect its full 2 s and then starting
/// a fresh 2 s read deadline means a nominal 2 s call can legitimately take over 4 s, and
/// ``HerdSnapshotBuilder`` makes two such calls per running session while the app polls at 1 Hz. One
/// deadline created before the first syscall, with every phase handed only what is left, is what makes
/// the advertised timeout an actual upper bound.
///
/// Monotonic by construction: it is built on `DispatchTime`, which derives from `mach_absolute_time`
/// and therefore cannot be dragged backwards by an NTP correction or a manual clock change the way
/// `Date` can. A wall-clock deadline can silently become a hang.
///
/// Thread-safety: an immutable `Sendable` value. ``remaining`` is computed on each access.
struct Deadline: Sendable {
    /// Longest budget accepted, in seconds.
    ///
    /// Guards the nanosecond conversion below against overflow. An hour is far beyond any sensible
    /// herdr call, so clamping here can only ever turn an absurd argument into a merely large one.
    private static let maximumSeconds: TimeInterval = 3600

    /// The monotonic instant at which the budget is exhausted.
    private let expiry: DispatchTime

    /// Starts a budget running now.
    ///
    /// - Parameter seconds: Total budget. Negative values are treated as already expired, and values
    ///   above ``maximumSeconds`` are clamped.
    init(after seconds: TimeInterval) {
        let clamped = min(max(0, seconds), Self.maximumSeconds)
        expiry = DispatchTime.now() + .nanoseconds(Int(clamped * 1_000_000_000))
    }

    /// Seconds left, never negative.
    ///
    /// Returns exactly `0` once the deadline has passed, so callers can pass this straight to a phase
    /// without having to clamp it themselves.
    var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = expiry.uptimeNanoseconds
        guard end > now else { return 0 }
        return TimeInterval(end - now) / 1_000_000_000
    }

    /// Whether the budget is used up.
    var hasExpired: Bool { remaining <= 0 }

    /// Milliseconds left, clamped to at least 1 and at most `Int32.max`, for `poll(2)`.
    ///
    /// Never returns 0, because `poll` treats a 0 timeout as "return immediately", which would turn a
    /// nearly-expired deadline into a busy loop rather than a clean timeout. Callers check
    /// ``hasExpired`` first and throw, so a value of 1 only ever means "one last attempt".
    var pollMilliseconds: Int32 {
        Int32(min(max(1, (remaining * 1000).rounded()), TimeInterval(Int32.max)))
    }
}
