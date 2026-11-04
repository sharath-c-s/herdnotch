import Testing

@testable import NotchCore

@Suite struct HealthReportTests {
    private let mb: UInt64 = 1024 * 1024
    private let gb: UInt64 = 1024 * 1024 * 1024

    private func memory(swap: UInt64 = 0, pressure: MemoryPressure = .normal) -> MemoryReading {
        MemoryReading(usedBytes: 8 * gb, totalBytes: 16 * gb, swapUsedBytes: swap, pressure: pressure)
    }

    private func readings(
        cpu: Double = 10, load: Double = 1, swap: UInt64 = 0, pressure: MemoryPressure = .normal, swapGrowing: Bool = false,
        disk: Double? = 50, thermal: ThermalLevel = .nominal, limit: Int? = nil, lowPower: Bool = false
    ) -> HealthReadings {
        HealthReadings(
            cpuPercent: cpu, loadAverage: load, cores: 8, memory: memory(swap: swap, pressure: pressure),
            swapGrowing: swapGrowing, diskUsedPercent: disk, thermal: thermal, cpuSpeedLimit: limit, lowPowerMode: lowPower)
    }

    private func proc(
        _ name: String, pid: Int32, parent: Int32 = 1, cpu: Double = 0, bytes: UInt64 = 10 * 1024 * 1024, family: String? = nil
    ) -> ProcessUsage {
        ProcessUsage(pid: pid, name: name, family: family ?? name, cpuPercent: cpu, residentBytes: bytes, parentPid: parent)
    }

    private func build(
        _ r: HealthReadings, _ processes: [ProcessUsage] = [], agents: [Int32: AgentIdentity] = [:], selfPid: Int32 = 999
    ) -> HealthReport {
        var table: [Int32: ProcessNode] = [:]
        for p in processes { table[p.pid] = ProcessNode(parentPid: p.parentPid, name: p.name) }
        return HealthReport.build(readings: r, processes: processes, table: table, agents: agents, selfPid: selfPid)
    }

    // MARK: pmset

    @Test func pmsetNoWarningFormHasNoLimit() {
        let text = """
            Note: No thermal warning level has been recorded
            Note: No performance warning level has been recorded
            Note: No CPU power status has been recorded
            """
        #expect(PmsetTherm.cpuSpeedLimit(text) == nil)
    }

    @Test func pmsetReadsSpeedLimit() {
        let text = """
            CPU_Scheduler_Limit = 100
            CPU_Available_CPUs = 8
            CPU_Speed_Limit = 70
            """
        #expect(PmsetTherm.cpuSpeedLimit(text) == 70)
        #expect(PmsetTherm.cpuSpeedLimit("CPU_Speed_Limit\t= 100\n") == 100)
        #expect(PmsetTherm.cpuSpeedLimit("CPU_Speed_Limit = abc") == nil)
    }

    // MARK: ps

    @Test func psParsesNormalLongAndMalformedLines() {
        let text = """
              1     0   0.0  1312     0 /sbin/launchd
            612   1  71.8 214016   0 /Library/Application Support/JAMF/Jamf.app/Contents/com.jamf.protect.security-extension
            90 1 41.1 90000 88 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
            55 1 3.0 100 501 Google Chrome Helper
            bad line
            7 1 x 5 0 /bin/y
            8 1 1.0 5 0
            """
        let entries = PsTable.parse(text)
        #expect(entries.map(\.pid) == [1, 612, 90, 55])
        #expect(entries[1].name == "com.jamf.protect.security-extension")
        #expect(entries[1].cpuPercent == 71.8 && entries[1].rssBytes == 214016 * 1024 && entries[1].uid == 0)
        #expect(entries[2].name == "WindowServer" && entries[2].uid == 88)
        #expect(entries[3].name == "Google Chrome Helper")
    }

    @Test func psUsagesCoverOnlyUnscannedProcessesAndFlagOtherUsers() {
        let entries = [
            PsEntry(pid: 1, parentPid: 0, cpuPercent: 80, rssBytes: 10, uid: 0, name: "launchd"),
            PsEntry(pid: 2, parentPid: 1, cpuPercent: 5, rssBytes: 10, uid: 501, name: "scanned"),
            PsEntry(pid: 3, parentPid: 999, cpuPercent: 1, rssBytes: 10, uid: 501, name: "ps"),
            PsEntry(pid: 4, parentPid: 1, cpuPercent: 2, rssBytes: 10, uid: 501, name: "mine"),
        ]
        let usages = PsTable.usages(entries, excluding: [2], currentUid: 501, selfPid: 999)
        #expect(usages.map(\.pid) == [1, 4])
        #expect(usages.map(\.isSystem) == [true, false])
    }

    // MARK: Attribution

    @Test func ownerWalksParentChainToKnownAgent() {
        let table: [Int32: ProcessNode] = [
            10: ProcessNode(parentPid: 1, name: "zsh"),
            20: ProcessNode(parentPid: 10, name: "claude"),
            30: ProcessNode(parentPid: 20, name: "node"),
            40: ProcessNode(parentPid: 30, name: "mcp-server"),
        ]
        let agents: [Int32: AgentIdentity] = [20: AgentIdentity(label: "nightly-Fups", sessionId: "s1")]
        let owner = AgentAttribution.owner(of: 40, table: table, agents: agents)
        #expect(owner?.pid == 20)
        #expect(owner?.identity.label == "nightly-Fups")
        #expect(AgentAttribution.owner(of: 20, table: table, agents: agents) == nil)
        #expect(AgentAttribution.owner(of: 10, table: table, agents: agents) == nil)
    }

    @Test func ownerFallsBackToProcessNameAndInterpreterArgv() {
        let table: [Int32: ProcessNode] = [
            20: ProcessNode(parentPid: 1, name: "claude"),
            21: ProcessNode(parentPid: 20, name: "x"),
            30: ProcessNode(parentPid: 1, name: "node", argv: ["node", "/opt/bin/codex", "--x"]),
            31: ProcessNode(parentPid: 30, name: "y"),
            50: ProcessNode(parentPid: 1, name: "node", argv: ["node", "/opt/bin/server.js"]),
            51: ProcessNode(parentPid: 50, name: "z"),
        ]
        #expect(AgentAttribution.owner(of: 21, table: table, agents: [:])?.identity.label == "claude (20)")
        #expect(AgentAttribution.owner(of: 31, table: table, agents: [:])?.identity.label == "codex (30)")
        #expect(AgentAttribution.owner(of: 51, table: table, agents: [:]) == nil)
    }

    @Test func ownerStopsOnParentCycle() {
        let table: [Int32: ProcessNode] = [
            5: ProcessNode(parentPid: 6, name: "a"), 6: ProcessNode(parentPid: 5, name: "b"),
        ]
        #expect(AgentAttribution.owner(of: 5, table: table, agents: [:]) == nil)
    }

    @Test func swarmsGroupDescendantsPerAgent() {
        let agents: [Int32: AgentIdentity] = [20: AgentIdentity(label: "alpha"), 60: AgentIdentity(label: "beta")]
        let processes = [
            proc("claude", pid: 20), proc("node", pid: 30, parent: 20, cpu: 1, bytes: 300 * mb, family: ResourceDiagnosis.mcpFamily),
            proc("node", pid: 31, parent: 30, cpu: 2, bytes: 200 * mb, family: ResourceDiagnosis.mcpFamily),
            proc("claude", pid: 60), proc("tool", pid: 61, parent: 60, bytes: gb),
            proc("Safari", pid: 70),
        ]
        var table: [Int32: ProcessNode] = [:]
        for p in processes { table[p.pid] = ProcessNode(parentPid: p.parentPid, name: p.name) }
        let swarms = AgentAttribution.swarms(processes: processes, table: table, agents: agents, minMembers: 1)
        #expect(swarms.map(\.identity.label) == ["beta", "alpha"])
        #expect(swarms[1].count == 2 && swarms[1].mcpCount == 2 && swarms[1].cpuPercent == 3 && swarms[1].residentBytes == 500 * mb)
        #expect(LoadFormat.agentSwarmTitle(swarms[1]) == "2 MCP processes")
        #expect(LoadFormat.agentSwarmTitle(swarms[0]) == "1 process")
        // Default minimum of 2 drops beta (1 member).
        #expect(AgentAttribution.swarms(processes: processes, table: table, agents: agents).map(\.identity.label) == ["alpha"])
    }

    // MARK: Rows

    @Test func idleMacIsAllGreenAndNothingToImprove() {
        let report = build(readings(), [proc("Safari", pid: 70, cpu: 3, bytes: 500 * mb)])
        #expect(report.rows.allSatisfy { $0.level == .ok })
        #expect(report.suggestions.isEmpty)
    }

    @Test func rowLevelsFollowThresholds() {
        func level(_ id: String, _ r: HealthReadings) -> HealthLevel {
            HealthReport.rows(for: r).first { $0.id == id }!.level
        }
        #expect(level("cpu", readings(cpu: 95)) == .limiting)
        #expect(level("cpu", readings(cpu: 70)) == .elevated)
        #expect(level("load", readings(load: 12)) == .limiting)
        #expect(level("load", readings(load: 8)) == .elevated)
        #expect(level("memory", readings(pressure: .warn)) == .elevated)
        #expect(level("memory", readings(pressure: .critical)) == .limiting)
        #expect(level("swap", readings(swap: 2 * gb)) == .elevated)
        #expect(level("swap", readings(pressure: .warn, swapGrowing: true)) == .limiting)
        #expect(level("disk", readings(disk: 95)) == .limiting)
        #expect(level("disk", readings(disk: 85)) == .elevated)
        #expect(level("thermal", readings(thermal: .fair)) == .elevated)
        #expect(level("thermal", readings(thermal: .serious)) == .limiting)
        #expect(level("thermal", readings(limit: 70)) == .limiting)
        #expect(level("thermal", readings(limit: 100)) == .ok)
        #expect(level("lowpower", readings(lowPower: true)) == .elevated)
    }

    @Test func diskRowIsHiddenUntilMeasured() {
        #expect(!HealthReport.rows(for: readings(disk: nil)).contains { $0.id == "disk" })
    }

    // MARK: Top lists

    @Test func topListsHaveFiveEntriesAndIncludeTheResidualRow() {
        let processes = (1...8).map { proc("p\($0)", pid: Int32($0), cpu: Double($0), bytes: UInt64($0) * mb) }
        let report = build(readings(cpu: 50), processes)
        #expect(report.topCPU.count == 5 && report.topMemory.count == 5)
        #expect(report.topCPU.first?.pid == ResourceDiagnosis.residualPid)
        #expect(report.topCPU.dropFirst().first?.name == "p8")
        #expect(report.topMemory.first?.pid == ResourceDiagnosis.residualPid)
    }

    // MARK: Suggestions

    @Test func thermalLimitIsTheTopSuggestion() {
        let report = build(
            readings(thermal: .serious, limit: 70, lowPower: true), [proc("Xcode", pid: 5, bytes: 4 * gb)])
        #expect(report.suggestions.first?.id == "thermal")
        #expect(report.suggestions.first?.text.contains("CPU limited to 70%") == true)
        #expect(report.suggestions.map(\.impact) == report.suggestions.map(\.impact).sorted(by: >))
        #expect(report.suggestions.map(\.id).contains("lowpower"))
    }

    @Test func fairThermalIsAMildSuggestion() {
        let report = build(readings(thermal: .fair))
        #expect(report.suggestions.first?.id == "thermal")
        #expect(report.suggestions.first!.impact < 95)
    }

    @Test func bigAppSuggestsItsLargestProcess() {
        let processes = [
            proc("Xcode", pid: 5, bytes: 4 * gb), proc("Xcode", pid: 6, bytes: gb),
            proc("Slack", pid: 7, bytes: 3 * gb), proc("Notes", pid: 8, bytes: gb),
        ]
        let report = build(readings(pressure: .warn), processes)
        let apps = report.suggestions.filter { $0.id.hasPrefix("app-") }
        #expect(apps.map(\.id) == ["app-Xcode", "app-Slack"])
        #expect(apps[0].target == .process(pid: 5))
        #expect(apps[0].text == "Xcode uses 5 GB. Quitting it frees that memory.")
    }

    @Test func bigAppIsQuietAtNormalPressure() {
        let report = build(readings(), [proc("Xcode", pid: 5, bytes: 4 * gb)])
        #expect(!report.suggestions.contains { $0.id.hasPrefix("app-") })
    }

    @Test func swapOutranksABigApp() {
        let report = build(
            readings(pressure: .warn, swapGrowing: true), [proc("Xcode", pid: 5, bytes: 40 * gb)])
        #expect(report.suggestions.first?.id == "swap")
        #expect(report.suggestions.contains { $0.id == "app-Xcode" })
    }

    @Test func agentProcessesNeverGetAQuitHint() {
        let processes = (0..<3).map { proc("claude", pid: 100 + Int32($0), bytes: 2 * gb) }
            + [proc("2.1.316", pid: 200, bytes: 2 * gb), proc("bg-pty-host", pid: 201, parent: 100, bytes: 2 * gb)]
        let report = build(readings(pressure: .critical), processes)
        #expect(!report.suggestions.contains { $0.id.hasPrefix("app-") })
        #expect(AgentAttribution.agentKind(ProcessNode(parentPid: 1, name: "2.1.316")) == "claude")
        #expect(AgentAttribution.agentKind(ProcessNode(parentPid: 1, name: "2.1")) == nil)
    }

    @Test func registeredAgentIsNotSwallowedByAnUnregisteredDaemon() {
        let processes = [
            proc("claude", pid: 20), proc("claude", pid: 30, parent: 20, bytes: gb),
            proc("node", pid: 31, parent: 30, bytes: gb), proc("node", pid: 32, parent: 30, bytes: gb),
        ]
        var table: [Int32: ProcessNode] = [:]
        for p in processes { table[p.pid] = ProcessNode(parentPid: p.parentPid, name: p.name) }
        let agents: [Int32: AgentIdentity] = [30: AgentIdentity(label: "session")]
        #expect(AgentAttribution.owner(of: 30, table: table, agents: agents) == nil)
        let swarms = AgentAttribution.swarms(processes: processes, table: table, agents: agents)
        #expect(swarms.map(\.agentPid) == [30])
        #expect(swarms[0].count == 2)
    }

    @Test func spotlightAppearsOnceNotAsAHotSystemProcess() {
        func sys(_ name: String, pid: Int32) -> ProcessUsage {
            ProcessUsage(pid: pid, name: name, family: name, cpuPercent: 80, residentBytes: 10 * mb, parentPid: 1, isSystem: true)
        }
        let ids = build(readings(), [sys("mds_stores", pid: 11), sys("corespotlightd", pid: 12), sys("WindowServer", pid: 13)])
            .suggestions.map(\.id)
        #expect(ids.filter { $0.hasPrefix("system-") } == ["system-13"])
        #expect(ids.contains("spotlight"))
    }

    @Test func swarmTitlesUseTheSingular() {
        let one = AgentSwarm(
            agentPid: 1, identity: AgentIdentity(label: "a"), count: 1, mcpCount: 1, cpuPercent: 0, residentBytes: 0)
        #expect(LoadFormat.agentSwarmTitle(one) == "1 MCP process")
    }

    @Test func diskSwapAndSpotlightRules() {
        let report = build(
            readings(pressure: .warn, swapGrowing: true, disk: 93),
            [proc("mdworker_shared", pid: 11, cpu: 20), proc("mdworker_shared", pid: 12, cpu: 15)])
        let ids = report.suggestions.map(\.id)
        #expect(ids == ["swap", "disk", "spotlight"])
        #expect(report.suggestions[2].target == .process(pid: 11))
        #expect(!build(readings(disk: 89)).suggestions.contains { $0.id == "disk" })
        #expect(!build(readings(pressure: .normal, swapGrowing: true)).suggestions.contains { $0.id == "swap" })
    }

    @Test func memoryPressureWithoutGrowingSwapIsAMilderSuggestion() {
        let ids = build(readings(pressure: .warn)).suggestions.map(\.id)
        #expect(ids == ["pressure"])
        #expect(build(readings(pressure: .normal)).suggestions.isEmpty)
    }

    @Test func agentProcessesAreNamedBySessionAndNeverCountedAsUnattributedSwarms() {
        let agents: [Int32: AgentIdentity] = [20: AgentIdentity(label: "alpha")]
        let processes = [proc("2.1.314", pid: 20, cpu: 40, bytes: 300 * mb, family: "2.1.314")]
        let report = build(readings(), processes, agents: agents)
        #expect(report.topCPU.first { $0.pid == 20 }?.name == "alpha")
        #expect(report.otherSwarms.isEmpty)
    }

    @Test func idleAgentSwarmsAreAggregatedAndPointAtTheBiggest() {
        let agents: [Int32: AgentIdentity] = [
            20: AgentIdentity(label: "alpha", sessionId: "sa"), 60: AgentIdentity(label: "beta", sessionId: "sb"),
        ]
        let processes = [
            proc("claude", pid: 20), proc("node", pid: 30, parent: 20, bytes: 400 * mb, family: ResourceDiagnosis.mcpFamily),
            proc("node", pid: 31, parent: 20, bytes: 400 * mb, family: ResourceDiagnosis.mcpFamily),
            proc("claude", pid: 60), proc("node", pid: 61, parent: 60, bytes: 300 * mb, family: ResourceDiagnosis.mcpFamily),
            proc("node", pid: 62, parent: 60, bytes: 300 * mb, family: ResourceDiagnosis.mcpFamily),
        ]
        let report = build(readings(), processes, agents: agents)
        let idle = report.suggestions.first { $0.id == "idle-agents" }
        #expect(idle?.text == "2 idle sessions hold 4 processes, 1.4 GB. Close the ones you are done with.")
        #expect(idle?.target == .agent(pid: 20, sessionId: "sa"))
        // Agent descendants never show up as big apps or unattributed swarms.
        #expect(report.otherSwarms.isEmpty)
    }

    @Test func busyOrSmallAgentSwarmsAreNotSuggested() {
        let agents: [Int32: AgentIdentity] = [20: AgentIdentity(label: "alpha")]
        let busy = [
            proc("claude", pid: 20), proc("node", pid: 30, parent: 20, cpu: 50, bytes: gb),
            proc("node", pid: 31, parent: 20, cpu: 50, bytes: gb),
        ]
        #expect(!build(readings(), busy, agents: agents).suggestions.contains { $0.id == "idle-agents" })
        let small = [
            proc("claude", pid: 20), proc("node", pid: 30, parent: 20, bytes: 10 * mb), proc("node", pid: 31, parent: 20, bytes: 10 * mb),
        ]
        #expect(!build(readings(), small, agents: agents).suggestions.contains { $0.id == "idle-agents" })
    }

    @Test func idleFollowsRegistryStatusForClaudeAndCPUForCodex() {
        let agents: [Int32: AgentIdentity] = [
            20: AgentIdentity(label: "busy-claude", registryStatus: "busy"),
            60: AgentIdentity(label: "idle-claude", registryStatus: "idle"),
            80: AgentIdentity(label: "quiet-codex"),
        ]
        func swarm(_ agent: Int32, cpu: Double) -> [ProcessUsage] {
            [proc("agent", pid: agent), proc("node", pid: agent + 1, parent: agent, cpu: cpu, bytes: 400 * mb),
             proc("node", pid: agent + 2, parent: agent, cpu: 0, bytes: 400 * mb)]
        }
        // A busy-status Claude is not idle even at 0% CPU; an idle-status one is idle even at 50%.
        #expect(!build(readings(), swarm(20, cpu: 0), agents: agents).suggestions.contains { $0.id == "idle-agents" })
        #expect(build(readings(), swarm(60, cpu: 50), agents: agents).suggestions.contains { $0.id == "idle-agents" })
        #expect(build(readings(), swarm(80, cpu: 0), agents: agents).suggestions.contains { $0.id == "idle-agents" })
        #expect(!build(readings(), swarm(80, cpu: 50), agents: agents).suggestions.contains { $0.id == "idle-agents" })
    }

    @Test func singleIdleSessionNamesItself() {
        let agents: [Int32: AgentIdentity] = [20: AgentIdentity(label: "nightly-Fups")]
        let processes = [proc("claude", pid: 20)] + (30...38).map {
            proc("node", pid: Int32($0), parent: 20, bytes: 90 * mb, family: ResourceDiagnosis.mcpFamily)
        }
        let report = build(readings(), processes, agents: agents)
        #expect(report.agentSwarms.first?.count == 9)
        #expect(report.suggestions.first { $0.id == "idle-agents" }?.text
            == "nightly-Fups is idle but holds 9 MCP processes, 810 MB. Close the session to free them.")
    }

    @Test func hotSystemProcessIsNamedAndCannotBeQuit() {
        func sys(_ name: String, pid: Int32, cpu: Double, bytes: UInt64 = 10 * mb) -> ProcessUsage {
            ProcessUsage(pid: pid, name: name, family: name, cpuPercent: cpu, residentBytes: bytes, isSystem: true)
        }
        let report = build(readings(), [sys("com.jamf.protect.security-extension", pid: 612, cpu: 71.8), sys("WindowServer", pid: 90, cpu: 50)])
        let hot = report.suggestions.filter { $0.id.hasPrefix("system-") }
        #expect(hot.map(\.id) == ["system-612"])
        #expect(hot[0].text == "com.jamf.protect.security-extension is using 72% CPU; it is a system or managed process you cannot quit from here.")
        #expect(hot[0].target == .none)
        // Not a big-app suggestion even when it is large.
        #expect(!build(readings(), [sys("kernel_task", pid: 0, cpu: 1, bytes: 4 * gb)]).suggestions.contains { $0.id.hasPrefix("app-") })
    }

    @Test func herdNotchItselfIsFlaggedOnlyWhenItIsATopContender() {
        let busy = [proc("HerdNotch", pid: 999, cpu: 19, bytes: 200 * mb), proc("a", pid: 1, cpu: 1)]
        #expect(build(readings(), busy, selfPid: 999).suggestions.map(\.id) == ["self"])
        let quiet = [proc("HerdNotch", pid: 999, cpu: 1, bytes: 200 * mb), proc("a", pid: 1, cpu: 30)]
        #expect(build(readings(), quiet, selfPid: 999).suggestions.isEmpty)
        let behind = [proc("HerdNotch", pid: 999, cpu: 6)] + (1...4).map { proc("p\($0)", pid: Int32($0), cpu: 50) }
        #expect(!build(readings(), behind, selfPid: 999).suggestions.contains { $0.id == "self" })
    }

    @Test func suggestionsOrderByImpactThenId() {
        let processes = [proc("Xcode", pid: 5, bytes: gb * 5 / 2), proc("mdworker", pid: 6, cpu: 40)]
        let report = build(readings(pressure: .warn, disk: 95, lowPower: true), processes)
        #expect(report.suggestions.map(\.id) == ["disk", "pressure", "spotlight", "app-Xcode", "lowpower"])
    }
}
