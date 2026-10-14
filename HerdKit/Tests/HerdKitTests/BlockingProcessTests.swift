import Foundation
import Testing

@testable import HerdKit

@Suite struct BlockingProcessTests {
    @Test func outputPastThePipeBufferDoesNotDeadlock() throws {
        let result = try BlockingProcess.run("/usr/bin/head", ["-c", "300000", "/dev/zero"], timeout: 10)
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == 300_000)
    }

    @Test func aTimeoutKillsTheProcessAndFails() throws {
        let started = Date()
        let result = try BlockingProcess.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(!result.succeeded)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aTermIgnoringChildHoldingThePipesIsStillCutOff() throws {
        let started = Date()
        let result = try BlockingProcess.run("/bin/sh", ["-c", "trap '' TERM; sleep 5"], timeout: 0.5)
        #expect(!result.succeeded)
        #expect(Date().timeIntervalSince(started) < 0.5 + 0.5 + 0.5)
    }

    @Test func nonZeroExitAndMissingExecutable() throws {
        #expect(try BlockingProcess.run("/usr/bin/false", []).status == 1)
        #expect(throws: (any Error).self) { try BlockingProcess.run("/nonexistent/x", []) }
    }
}
