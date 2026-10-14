import Foundation
import Testing

@testable import NotchCore

struct LongTaskRuleTests {
    @Test func thresholdAppliesToBothLandings() {
        let long = LongTaskRule.evaluate(workedFor: 12 * 60 + 30, thresholdMinutes: 5, landedOnDone: true, isLocal: false)
        #expect(long == .init(announce: true, detail: "finished after 12m"))
        #expect(LongTaskRule.evaluate(workedFor: 5 * 60, thresholdMinutes: 5, landedOnDone: false, isLocal: true).announce)
        #expect(!LongTaskRule.evaluate(workedFor: 90, thresholdMinutes: 5, landedOnDone: false, isLocal: true).announce)
    }

    @Test func herdrDoneAlwaysAnnouncesAndOnlyGainsDurationWhenLong() {
        #expect(LongTaskRule.evaluate(workedFor: 5 * 60 - 1, thresholdMinutes: 5, landedOnDone: true, isLocal: false)
            == .init(announce: true, detail: nil))
        #expect(!LongTaskRule.evaluate(workedFor: 3600, thresholdMinutes: 5, landedOnDone: false, isLocal: false).announce)
    }

    @Test func zeroThresholdKeepsTodaysHerdrDoneAndLimitsLocalIdle() {
        #expect(LongTaskRule.evaluate(workedFor: 3, thresholdMinutes: 0, landedOnDone: true, isLocal: false)
            == .init(announce: true, detail: nil))
        #expect(!LongTaskRule.evaluate(workedFor: 59, thresholdMinutes: 0, landedOnDone: false, isLocal: true).announce)
        #expect(LongTaskRule.evaluate(workedFor: 60, thresholdMinutes: 0, landedOnDone: false, isLocal: true)
            == .init(announce: true, detail: "finished after 1m"))
        // herdr never announced a working to idle flip, and still does not.
        #expect(!LongTaskRule.evaluate(workedFor: 3600, thresholdMinutes: 0, landedOnDone: false, isLocal: false).announce)
    }

    @Test func formatsDurations() {
        #expect(LongTaskRule.format(0) == "0s")
        #expect(LongTaskRule.format(59.9) == "59s")
        #expect(LongTaskRule.format(60) == "1m")
        #expect(LongTaskRule.format(59 * 60 + 59) == "59m")
        #expect(LongTaskRule.format(3600) == "1h")
        #expect(LongTaskRule.format(3600 + 5 * 60) == "1h 5m")
        #expect(LongTaskRule.format(-5) == "0s")
    }
}

@Suite struct ShortDurationTests {
    @Test func usageCardStyle() {
        func text(_ seconds: TimeInterval) -> String {
            ShortDuration.format(seconds: seconds, showsSeconds: false, showsDays: true)
        }
        #expect(text(59) == "<1m")
        #expect(text(60) == "1m")
        #expect(text(42 * 60 + 59) == "42m")
        #expect(text(3600) == "1h 0m")
        #expect(text(3600 + 4 * 60) == "1h 4m")
        #expect(text(24 * 3600 - 60) == "23h 59m")
        #expect(text(3 * 86400 + 5 * 3600) == "3d")
    }
}
