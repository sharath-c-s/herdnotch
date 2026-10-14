import Foundation
import Testing

@testable import UsageKit

@Suite struct OpenCodeUsageTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func body(rollingPercent: Double, rollingReset: Date) -> String {
        """
        {"usage":{
          "rolling":{"percent":\(rollingPercent),"resetsAt":"\(UsageParseFormat.iso(rollingReset))"},
          "weekly":{"percent":30,"resetsAt":"2026-10-19T00:00:00Z"},
          "monthly":{"percent":12.5,"resetsAt":"2026-11-01T00:00:00Z"}}}
        """
    }

    @Test func mapsThreeWindows() throws {
        let response = json(body(rollingPercent: 20, rollingReset: Self.now.addingTimeInterval(3600)))
        let reading = try #require(OpenCodeUsageMapper.map(response, capturedAt: Self.now))
        #expect(reading.windows.map(\.label) == ["Session", "Weekly", "Monthly"])
        #expect(reading.windows.map(\.usedPercent) == [20, 30, 12.5])
        #expect(reading.windows[0].resetsAt == Self.now.addingTimeInterval(3600))
        #expect(reading.windows[2].periodSeconds == UsagePeriod.month)
        #expect(reading.plan == "Go")
    }

    @Test func zeroUsageRollingResetOneFullPeriodAwayIsPlaceholder() throws {
        let placeholder = json(body(rollingPercent: 0, rollingReset: Self.now.addingTimeInterval(5 * 3600)))
        #expect(try #require(OpenCodeUsageMapper.map(placeholder, capturedAt: Self.now)).windows[0].resetsAt == nil)

        // Real usage anchors the reset inside the period, so a countdown stays even at 0 whole percent.
        let started = json(body(rollingPercent: 0, rollingReset: Self.now.addingTimeInterval(4 * 3600)))
        #expect(try #require(OpenCodeUsageMapper.map(started, capturedAt: Self.now)).windows[0].resetsAt != nil)

        // Weekly and monthly never drop their reset.
        #expect(try #require(OpenCodeUsageMapper.map(placeholder, capturedAt: Self.now)).windows[1].resetsAt != nil)
    }

    @Test func placeholderTestPrefersServerDateHeaderOverLocalClock() throws {
        // The local clock is far off: the Date header is the reference, not capturedAt.
        let header = try #require(UsageParse.httpDate("Fri, 15 Jan 2027 08:00:00 GMT"))
        let skewed = json(
            body(rollingPercent: 0, rollingReset: header.addingTimeInterval(5 * 3600)),
            headers: ["Date": "Fri, 15 Jan 2027 08:00:00 GMT"]
        )
        #expect(try #require(OpenCodeUsageMapper.map(skewed, capturedAt: Self.now)).windows[0].resetsAt == nil)
    }

    @Test func malformedBodyIsNil() {
        #expect(OpenCodeUsageMapper.map(json(#"{"usage":{"rolling":{"percent":1}}}"#), capturedAt: Self.now) == nil)
        #expect(OpenCodeUsageMapper.map(json("<html>"), capturedAt: Self.now) == nil)
    }

    // MARK: key lookup + source

    /// Fake sqlite3: the migration query says "imported"; the key query returns `key`.
    private func sqliteRunner(key: String?, imported: Bool = true) -> FakeRunner {
        FakeRunner { call in
            guard call.executable == "/usr/bin/sqlite3" else { return ProcessResult(succeeded: false) }
            let sql = call.arguments.last ?? ""
            if sql.contains("FROM migration") { return ProcessResult(succeeded: true, stdout: imported ? "1\n" : "") }
            return ProcessResult(succeeded: true, stdout: key.map { $0 + "\n" } ?? "")
        }
    }

    private func source(_ http: FakeHTTPClient, runner: FakeRunner, home: URL) -> OpenCodeUsageSource {
        OpenCodeUsageSource(context: UsageContext(http: http, loopbackHTTP: http, runner: runner, environment: [:], home: home))
    }

    @Test func readsKeyFromDatabaseReadOnlyAndCallsUsageEndpoint() async throws {
        let home = try makeHome(files: [".local/share/opencode/opencode.db": "", ".local/share/opencode/opencode.db-wal": ""])
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = sqliteRunner(key: "test-go-key")
        let http = FakeHTTPClient { _ in json(self.body(rollingPercent: 5, rollingReset: Self.now.addingTimeInterval(3600))) }
        let reading = try await source(http, runner: runner, home: home).load(now: Self.now)

        let sqlite = try #require(runner.calls.first { $0.executable == "/usr/bin/sqlite3" })
        #expect(sqlite.arguments.contains("-readonly"))
        #expect(sqlite.arguments.contains(home.path + "/.local/share/opencode/opencode.db"))
        #expect(!runner.calls.contains { $0.arguments.contains { $0.hasSuffix("-wal") } })
        #expect(http.requests.first?.url.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(http.requests.first?.headers["Authorization"] == "Bearer test-go-key")
        #expect(reading.windows.count == 3)
    }

    @Test func fallsBackToAuthJsonWhenNoDatabaseHasCredentialTable() async throws {
        let home = try makeHome(files: [".local/share/opencode/auth.json": #"{"opencode-go":{"type":"api","key":"test-go-key"},"other":{}}"#])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(self.body(rollingPercent: 5, rollingReset: Self.now.addingTimeInterval(3600))) }
        _ = try await source(http, runner: FakeRunner(), home: home).load(now: Self.now)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer test-go-key")
    }

    @Test func importedDatabaseWithoutKeyDoesNotReviveAuthJson() async throws {
        let home = try makeHome(files: [
            ".local/share/opencode/opencode.db": "",
            ".local/share/opencode/auth.json": #"{"opencode-go":{"key":"stale-key"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient()
        await #expect(throws: UsageFailure.notSetUp("log in to OpenCode Go")) {
            try await source(http, runner: sqliteRunner(key: nil), home: home).load(now: Self.now)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func entitlementErrorIsNotSetUp() async throws {
        let home = try makeHome(files: [".local/share/opencode/opencode.db": ""])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(403, #"{"type":"error","error":{"type":"EntitlementError","message":"no go"}}"#) }
        await #expect(throws: UsageFailure.notSetUp("no OpenCode Go subscription")) {
            try await source(http, runner: sqliteRunner(key: "test-go-key"), home: home).load(now: Self.now)
        }
    }

    @Test func rateLimitCarriesRetryAfter() async throws {
        let home = try makeHome(files: [".local/share/opencode/opencode.db": ""])
        defer { try? FileManager.default.removeItem(at: home) }
        let http = FakeHTTPClient { _ in json(429, "{}", headers: ["Retry-After": "90"]) }
        await #expect(throws: UsageFailure.rateLimited(retryAfter: 90)) {
            try await source(http, runner: sqliteRunner(key: "test-go-key"), home: home).load(now: Self.now)
        }
    }
}

enum UsageParseFormat {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
