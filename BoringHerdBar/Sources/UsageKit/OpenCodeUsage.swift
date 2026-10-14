import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

enum OpenCodeUsageMapper {
    /// How far from exactly one full period a zero-usage rolling reset may sit and still count as the placeholder.
    /// OpenCode rounds up to whole seconds and HTTP `Date` has whole-second precision.
    static let placeholderTolerance: TimeInterval = 2

    static func map(_ response: HTTPResponse, capturedAt: Date) -> UsageReading? {
        guard let body = UsageParse.jsonObject(response.body), let usage = body["usage"] as? [String: Any] else { return nil }
        // Comparing two server-authored instants removes local clock skew from the placeholder test.
        let reference = response.header("date").flatMap(UsageParse.httpDate) ?? capturedAt
        guard let session = window(usage["rolling"], "Session", UsagePeriod.session, reference, dropsPlaceholder: true),
              let weekly = window(usage["weekly"], "Weekly", UsagePeriod.week, reference),
              let monthly = window(usage["monthly"], "Monthly", UsagePeriod.month, reference)
        else { return nil }
        return UsageReading(windows: [session, weekly, monthly], plan: "Go", extra: nil)
    }

    /// With no calls in the rolling window the API answers `resetsAt = now + 5h` on every request. That placeholder
    /// means "if you started now", so it becomes nil. Weekly and monthly resets are calendar instants and are kept.
    private static func window(
        _ raw: Any?, _ label: String, _ period: TimeInterval, _ reference: Date, dropsPlaceholder: Bool = false
    ) -> UsageWindow? {
        guard let object = raw as? [String: Any], let percent = UsageParse.number(object["percent"]),
              let resetText = object["resetsAt"] as? String, let reset = UsageParse.iso8601(resetText)
        else { return nil }
        let used = UsageParse.clampPercent(percent)
        var resetsAt: Date? = reset
        if dropsPlaceholder, used == 0, abs(reset.timeIntervalSince(reference) - period) <= placeholderTolerance {
            resetsAt = nil
        }
        return UsageWindow(label: label, usedPercent: used, resetsAt: resetsAt, periodSeconds: period)
    }

    /// The upstream error discriminator (`AuthError`, `EntitlementError`), nil for non-JSON bodies.
    static func errorType(_ response: HTTPResponse) -> String? {
        ((UsageParse.jsonObject(response.body)?["error"] as? [String: Any])?["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// Reads the `opencode-go` key from OpenCode's channel databases (`credential` table, OpenCode 2) with
/// `/usr/bin/sqlite3 -readonly`, falling back to `auth.json` (OpenCode 1).
struct OpenCodeAuthStore: Sendable {
    var context: UsageContext

    static let migrationSQL = "SELECT 1 FROM migration WHERE id = '20260805200742_import_legacy_credentials' LIMIT 1;"
    static let goKeySQL = """
        SELECT json_extract(value,'$.key')
        FROM credential
        WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

    var dataDirectory: String {
        if let override = context.env("OPENCODE_DATA_DIR") { return context.expandHome(override) }
        if let xdg = context.env("XDG_DATA_HOME") { return context.expandHome(xdg) + "/opencode" }
        return context.home.path + "/.local/share/opencode"
    }

    /// Every `opencode*.db` (one per release channel), path-sorted. The `.db` suffix excludes `-wal`/`-shm`.
    func databaseFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory)) ?? []
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.sorted().map { dataDirectory + "/" + $0 }
    }

    /// The non-empty key, or nil when the user is not logged into OpenCode Go. Throws when a database exists but
    /// cannot be read, so broken storage is never mistaken for a logout.
    func goAPIKey() async throws -> String? {
        var hasCredentialTable = false
        var failure = false
        for path in databaseFiles() {
            do {
                guard try await query(path, Self.migrationSQL) != nil else { continue }
                hasCredentialTable = true
                if let key = try await query(path, Self.goKeySQL) { return key }
            } catch SQLiteFailure.missingTable {
                continue
            } catch {
                failure = true
            }
        }
        if failure { throw UsageFailure.failed("OpenCode database unreadable") }
        // After OpenCode 2 imports auth.json into a database, a logout must not be revived by the file.
        if hasCredentialTable { return nil }
        guard let text = readText(dataDirectory + "/auth.json"),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let entry = object["opencode-go"] as? [String: Any]
        else { return nil }
        return (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private enum SQLiteFailure: Error { case missingTable, failed }

    private func query(_ path: String, _ sql: String) async throws -> String? {
        var result = try await run(path, sql, extra: ["-readonly"])
        // A WAL database whose -shm cannot be opened read-only fails under -readonly. Retry with a connection that
        // may set up the sidecars but is still refused every write by `query_only`.
        if !result.succeeded { result = try await run(path, sql, extra: ["-cmd", "PRAGMA query_only = ON"]) }
        guard result.succeeded else {
            throw result.stderr.localizedCaseInsensitiveContains("no such table") ? SQLiteFailure.missingTable : SQLiteFailure.failed
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func run(_ path: String, _ sql: String, extra: [String]) async throws -> ProcessResult {
        try await context.runner.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-batch", "-noheader"] + extra + ["-cmd", ".timeout 1000", path, sql],
            timeout: 5
        )
    }
}

struct OpenCodeUsageSource: UsageSource {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    var context: UsageContext

    func load(now: Date) async throws -> UsageReading {
        guard let key = try await OpenCodeAuthStore(context: context).goAPIKey() else {
            throw UsageFailure.notSetUp("log in to OpenCode Go")
        }
        let response: HTTPResponse
        do {
            response = try await context.http.send(HTTPRequest(
                url: Self.usageURL,
                headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                timeout: 15
            ))
        } catch {
            throw UsageFailure.failed("connection failed")
        }
        if response.statusCode == 401 { throw UsageFailure.notSetUp("OpenCode Go key rejected, log in again") }
        if response.statusCode == 403, OpenCodeUsageMapper.errorType(response) == "EntitlementError" {
            throw UsageFailure.notSetUp("no OpenCode Go subscription")
        }
        guard (200..<300).contains(response.statusCode) else { throw commonFailure(response, now: now) }
        guard let reading = OpenCodeUsageMapper.map(response, capturedAt: now) else { throw UsageFailure.failed("invalid response") }
        return reading
    }
}
