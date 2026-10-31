import Foundation

// Adapted from OpenUsage (https://github.com/robinebers/openusage), MIT License, Copyright (c) 2026 Robin Ebers.

/// Finds a running Codeium-derived language server (Antigravity's `language_server`, or the `agy` CLI) and returns
/// the CSRF token and listening ports for its local Connect-RPC service. Scans `ps` and `lsof` through argv arrays.
struct LanguageServerDiscovery: Sendable {
    struct Options: Sendable {
        var processName: String
        /// Lowercased values matched against `--app_data_dir` / `--ide_name` / `--override_ide_name` (exact), then a
        /// `/marker/` path substring. Empty matches any instance.
        var markers: [String]
        /// Flag carrying the CSRF token. Empty means the process has none.
        var csrfFlag: String
        /// Optional flag carrying an HTTP fallback port.
        var portFlag: String?
    }

    struct Result: Sendable {
        var csrf: String
        var ports: [Int]
        var extensionPort: Int?
    }

    var runner: any ProcessRunner

    func discover(_ options: Options) async -> Result? {
        guard let ps = try? await runner.run(executable: "/bin/ps", arguments: ["-ax", "-o", "pid=,command="], timeout: 5),
              ps.succeeded
        else { return nil }
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.fileExists(atPath: $0) }
        for candidate in Self.rankedCandidates(psOutput: ps.stdout, options: options) {
            let csrf: String
            if options.csrfFlag.trimmingCharacters(in: .whitespaces).isEmpty {
                csrf = ""
            } else if let value = Self.extractFlag(command: candidate.command, flag: options.csrfFlag) {
                csrf = value
            } else {
                continue
            }
            let extensionPort = options.portFlag.flatMap { Self.extractFlag(command: candidate.command, flag: $0) }.flatMap { Int($0) }
            var ports: [Int] = []
            if let lsof, let result = try? await runner.run(
                executable: lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                timeout: 5
            ), result.succeeded {
                ports = Self.parseListeningPorts(result.stdout)
            }
            if ports.isEmpty && extensionPort == nil { continue }
            return Result(csrf: csrf, ports: ports, extensionPort: extensionPort)
        }
        return nil
    }

    /// Candidates matching the process name and markers, exact flag matches before path-substring matches.
    static func rankedCandidates(psOutput: String, options: Options) -> [(pid: Int32, command: String)] {
        let nameLower = options.processName.lowercased()
        let markers = options.markers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space])
            else { continue }
            let command = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            guard commandMatchesProcess(command: command, processNameLower: nameLower),
                  let rank = markerRank(command: command, markersLower: markers)
            else { continue }
            ranked.append((rank, pid, command))
        }
        return ranked.sorted { $0.rank < $1.rank }.map { (pid: $0.pid, command: $0.command) }
    }

    /// Value of `--flag value` or `--flag=value`.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flag + "=") {
                return String(part.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// Exact flag values rank 0 (so "antigravity" never matches "antigravity-next"), `/marker/` path substrings rank 1.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }
        let values = ["--ide_name", "--override_ide_name", "--app_data_dir"].compactMap {
            extractFlag(command: command, flag: $0)?.lowercased()
        }
        if !values.isEmpty { return markersLower.contains(where: values.contains) ? 0 : nil }
        let lower = command.lowercased()
        return markersLower.contains { lower.contains("/\($0)/") } ? 1 : nil
    }

    static func argv0(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) { return String(rest[..<end]) }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func commandMatchesProcess(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }
        let exeName = (argv0(command: command) as NSString).lastPathComponent.lowercased()
        if exeName == processNameLower { return true }
        let lower = command.lowercased()
        if processNameLower.count >= 8 { return exeName.hasPrefix("\(processNameLower)_") || lower.contains(processNameLower) }
        return lower.hasSuffix("/\(processNameLower)") || lower.contains("/\(processNameLower) ") || lower.contains("/\(processNameLower)\t")
    }

    /// Ports from `lsof -nP -iTCP -sTCP:LISTEN`, deduped and ascending.
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) where line.contains("LISTEN") {
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"), let port = Int(token[token.index(after: colon)...]), port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }
}
