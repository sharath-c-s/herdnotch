import Foundation
import Testing

@testable import UsageKit

@Suite struct KeychainReaderTests {
    @Test func aSlowFailureIsNotAskedAgain() async {
        let runner = FakeRunner()
        let reader = KeychainReader(runner: runner, promptThreshold: 0)
        #expect(await reader.read(service: "svc") == nil)
        #expect(await reader.read(service: "svc") == nil)
        #expect(runner.calls.count == 1)
    }

    @Test func aFastFailureIsRetried() async {
        let runner = FakeRunner()
        let reader = KeychainReader(runner: runner, promptThreshold: 60)
        _ = await reader.read(service: "svc")
        _ = await reader.read(service: "svc")
        #expect(runner.calls.count == 2)
    }

    @Test func aSlowItemNotFoundIsNotADenial() async {
        let runner = FakeRunner { _ in ProcessResult(succeeded: false, status: 44) }
        let reader = KeychainReader(runner: runner, promptThreshold: 0)
        _ = await reader.read(service: "svc")
        _ = await reader.read(service: "svc")
        #expect(runner.calls.count == 2)
    }

    @Test func aSlowOtherFailureIsADenial() async {
        let runner = FakeRunner { _ in ProcessResult(succeeded: false, status: 51) }
        let reader = KeychainReader(runner: runner, promptThreshold: 0)
        _ = await reader.read(service: "svc")
        _ = await reader.read(service: "svc")
        #expect(runner.calls.count == 1)
    }

    @Test func denialsAreRememberedPerService() async {
        let runner = FakeRunner { $0.arguments.contains("ok") ? ProcessResult(succeeded: true, stdout: "secret\n") : ProcessResult(succeeded: false) }
        let reader = KeychainReader(runner: runner, promptThreshold: 0)
        #expect(await reader.read(service: "denied") == nil)
        #expect(await reader.read(service: "ok") == "secret")
    }
}
