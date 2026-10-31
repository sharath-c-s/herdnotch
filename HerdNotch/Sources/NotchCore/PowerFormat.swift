import Foundation

/// Display formatting for battery readings. Pure value-in, string-out.
public enum PowerFormat {
    /// Raw max capacity over design capacity, as a whole percent. `nil` when either is missing or non-positive.
    public static func healthPercent(rawMaxCapacity: Int?, designCapacity: Int?) -> Int? {
        guard let rawMaxCapacity, let designCapacity, rawMaxCapacity > 0, designCapacity > 0 else { return nil }
        return Int((Double(rawMaxCapacity) / Double(designCapacity) * 100).rounded())
    }

    /// Instantaneous power in watts from milliamps and millivolts; the sign of `amperageMA` is dropped.
    public static func watts(amperageMA: Int, voltageMV: Int) -> Double {
        abs(Double(amperageMA) * Double(voltageMV)) / 1_000_000
    }

    /// One decimal, e.g. "12.3 W".
    public static func wattsText(_ watts: Double) -> String {
        String(format: "%.1f W", locale: Locale(identifier: "en_US_POSIX"), watts)
    }

    /// "3h 12m", "45m", or "--" when unknown. IOKit reports -1 while it is still calculating.
    public static func timeRemaining(minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "--" }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }

    public static func cycleText(_ cycles: Int?) -> String {
        cycles.map(String.init) ?? "--"
    }
}
