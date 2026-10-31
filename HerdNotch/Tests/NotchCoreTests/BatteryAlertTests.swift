import Foundation
import Testing

@testable import NotchCore

/// Tests for ``BatteryAlert``'s pure classification functions, against ``BatteryThresholds/default``
/// (low 20, warning 10, critical 5) unless a test names its own.
@Suite struct BatteryAlertTests {

    private let thresholds = BatteryThresholds.default

    // MARK: - tier(percent:thresholds:)

    @Test func tierAtExactBoundsReportsTheBound() {
        #expect(BatteryAlert.tier(percent: 20, thresholds: thresholds) == .low)
        #expect(BatteryAlert.tier(percent: 10, thresholds: thresholds) == .warning)
        #expect(BatteryAlert.tier(percent: 5, thresholds: thresholds) == .critical)
    }

    @Test func tierOneEitherSideOfEachBound() {
        #expect(BatteryAlert.tier(percent: 21, thresholds: thresholds) == .healthy)
        #expect(BatteryAlert.tier(percent: 19, thresholds: thresholds) == .low)
        #expect(BatteryAlert.tier(percent: 11, thresholds: thresholds) == .low)
        #expect(BatteryAlert.tier(percent: 9, thresholds: thresholds) == .warning)
        #expect(BatteryAlert.tier(percent: 6, thresholds: thresholds) == .warning)
        #expect(BatteryAlert.tier(percent: 4, thresholds: thresholds) == .critical)
    }

    @Test func tierAboveEveryBoundIsHealthy() {
        #expect(BatteryAlert.tier(percent: 100, thresholds: thresholds) == .healthy)
    }

    @Test func tierAtZeroIsCritical() {
        #expect(BatteryAlert.tier(percent: 0, thresholds: thresholds) == .critical)
    }

    // MARK: - crossedTier(previous:current:charging:thresholds:)

    @Test func crossedTierSingleCrossingReportsThatTier() {
        #expect(
            BatteryAlert.crossedTier(previous: 21, current: 20, charging: false, thresholds: thresholds) == .low
        )
        #expect(
            BatteryAlert.crossedTier(previous: 11, current: 10, charging: false, thresholds: thresholds) == .warning
        )
        #expect(
            BatteryAlert.crossedTier(previous: 6, current: 5, charging: false, thresholds: thresholds) == .critical
        )
    }

    @Test func crossedTierMultiThresholdJumpReportsMostSevere() {
        #expect(
            BatteryAlert.crossedTier(previous: 40, current: 3, charging: false, thresholds: thresholds) == .critical
        )
    }

    @Test func crossedTierNilPreviousReturnsNil() {
        #expect(
            BatteryAlert.crossedTier(previous: nil, current: 5, charging: false, thresholds: thresholds) == nil
        )
    }

    @Test func crossedTierNoRecrossReturnsNil() {
        // 10 (warning) was already crossed on some earlier step; 8 -> 7 crosses no further bound.
        #expect(
            BatteryAlert.crossedTier(previous: 8, current: 7, charging: false, thresholds: thresholds) == nil
        )
    }

    @Test func crossedTierWhileChargingReturnsNil() {
        #expect(
            BatteryAlert.crossedTier(previous: 21, current: 20, charging: true, thresholds: thresholds) == nil
        )
    }

    // MARK: - justReachedFull(previous:current:charging:)

    @Test func justReachedFullWhileChargingIsTrue() {
        #expect(BatteryAlert.justReachedFull(previous: 99, current: 100, charging: true) == true)
    }

    @Test func justReachedFullNotChargingIsFalse() {
        #expect(BatteryAlert.justReachedFull(previous: 99, current: 100, charging: false) == false)
    }

    @Test func justReachedFullNilPreviousIsFalse() {
        #expect(BatteryAlert.justReachedFull(previous: nil, current: 100, charging: true) == false)
    }

    @Test func justReachedFullAlreadyAtFullIsFalse() {
        #expect(BatteryAlert.justReachedFull(previous: 100, current: 100, charging: true) == false)
    }

    // MARK: - ordered(low:warning:critical:)

    @Test func orderedAlreadyOrderedIsUnchanged() {
        let result = BatteryAlert.ordered(low: 20, warning: 10, critical: 5)
        #expect(result == BatteryThresholds(low: 20, warning: 10, critical: 5))
    }

    @Test func orderedInvertedInputYieldsStrictOrder() {
        // warning (25) is above low (20): critical stays put, warning stays where it was (already above
        // critical), and low is pushed above warning instead.
        let result = BatteryAlert.ordered(low: 20, warning: 25, critical: 5)
        #expect(result.critical < result.warning)
        #expect(result.warning < result.low)
        #expect(result == BatteryThresholds(low: 26, warning: 25, critical: 5))
    }

    @Test func orderedEqualInputsAreSeparated() {
        let result = BatteryAlert.ordered(low: 10, warning: 10, critical: 10)
        #expect(result.critical < result.warning)
        #expect(result.warning < result.low)
        #expect(result == BatteryThresholds(low: 12, warning: 11, critical: 10))
    }
}
