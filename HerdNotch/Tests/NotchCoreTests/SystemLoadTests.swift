import Testing

@testable import NotchCore

@Suite struct SystemLoadTests {
    private let mb: UInt64 = 1024 * 1024
    private let gb: UInt64 = 1024 * 1024 * 1024

    private func memory(swap: UInt64 = 0, pressure: MemoryPressure = .normal) -> MemoryReading {
        MemoryReading(usedBytes: 8 * gb, totalBytes: 16 * gb, swapUsedBytes: swap, pressure: pressure)
    }

    private func usage(_ name: String, cpu: Double = 0, bytes: UInt64 = 0, family: String? = nil, pid: Int32 = 1) -> ProcessUsage {
        ProcessUsage(pid: pid, name: name, family: family ?? name, cpuPercent: cpu, residentBytes: bytes)
    }

    // MARK: CPU percent

    @Test func cpuPercentIsBusyShareOfDelta() {
        let a = CPUTicks(user: 100, system: 100, idle: 800, nice: 0)
        let b = CPUTicks(user: 130, system: 120, idle: 850, nice: 0)
        #expect(CPUTicks.cpuPercent(from: a, to: b) == 50)
    }

    @Test func niceCountsAsBusy() {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 0, system: 0, idle: 50, nice: 50)
        #expect(CPUTicks.cpuPercent(from: a, to: b) == 50)
    }

    @Test func zeroDeltaIsZero() {
        let a = CPUTicks(user: 5, system: 5, idle: 5, nice: 5)
        #expect(CPUTicks.cpuPercent(from: a, to: a) == 0)
    }

    @Test func counterWrapStillGivesTheDelta() {
        let a = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 9, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)
        #expect(CPUTicks.cpuPercent(from: a, to: b) == 50)
    }

    // MARK: Per-process CPU

    @Test func processCPUUsesOneCoreAsHundred() {
        let before = ProcessSample(pid: 7, name: "yes", family: "yes", cpuTimeNs: 1_000_000_000, residentBytes: 1)
        let after = ProcessSample(pid: 7, name: "yes", family: "yes", cpuTimeNs: 3_000_000_000, residentBytes: 1)
        let result = ResourceDiagnosis.processCPU(previous: [7: before], current: [after], interval: 2)
        #expect(result.first?.cpuPercent == 100)
    }

    @Test func processWithoutHistoryOrWithReusedPidReadsZero() {
        let fresh = ProcessSample(pid: 1, name: "a", family: "a", cpuTimeNs: 9, residentBytes: 1)
        let reused = ProcessSample(pid: 2, name: "b", family: "b", cpuTimeNs: 5, residentBytes: 1)
        let old = ProcessSample(pid: 2, name: "b", family: "b", cpuTimeNs: 50, residentBytes: 1)
        let result = ResourceDiagnosis.processCPU(previous: [2: old], current: [fresh, reused], interval: 2)
        #expect(result.map(\.cpuPercent) == [0, 0])
    }

    @Test func pressureLevelMapping() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warn)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == .normal)
    }

    // MARK: Top lists

    @Test func topThreeOrderedByCPUAndMemory() {
        let procs = [
            usage("a", cpu: 10, bytes: 5 * gb, pid: 1), usage("b", cpu: 300, bytes: 1 * gb, pid: 2),
            usage("c", cpu: 50, bytes: 9 * gb, pid: 3), usage("d", cpu: 200, bytes: 2 * gb, pid: 4),
            usage("e", cpu: 1, bytes: 3 * gb, pid: 5),
        ]
        let (byCPU, byMemory) = ResourceDiagnosis.rankings(cpuPercent: 95, memory: memory(), processes: procs, cores: 1)
        #expect(byCPU.prefix(3).map(\.name) == ["b", "d", "c"])
        #expect(byMemory.prefix(3).map(\.name) == ["c", "a", "e"])
    }

    @Test func tiesBreakByNameThenPid() {
        let procs = [usage("b", cpu: 5, pid: 9), usage("a", cpu: 5, pid: 8), usage("a", cpu: 5, pid: 3), usage("c", cpu: 5, pid: 1)]
        let byCPU = ResourceDiagnosis.rankings(cpuPercent: 20, memory: memory(), processes: procs, cores: 1).byCPU
        #expect(byCPU.prefix(3).map(\.pid) == [3, 8, 9])
    }

    // MARK: Residual row

    @Test func residualRowCoversWhatTheScanCannotSee() {
        let procs = [usage("app", cpu: 100, bytes: 2 * gb, pid: 1)]
        // 95% of 8 cores = 760; visible 100; residual 660. Used 8 GB; visible 2 GB; residual 6 GB.
        let (byCPU, byMemory) = ResourceDiagnosis.rankings(cpuPercent: 95, memory: memory(), processes: procs, cores: 8)
        #expect(byCPU.first?.name == ResourceDiagnosis.residualName)
        #expect(byCPU.first?.cpuPercent == 660)
        #expect(byMemory.first?.name == ResourceDiagnosis.residualName)
        #expect(byMemory.first?.residentBytes == 6 * gb)
    }

    @Test func residualClampsAtZeroAndRanksOnlyWhenItWins() {
        let procs = [usage("a", cpu: 900, bytes: 9 * gb, pid: 1), usage("b", cpu: 10, bytes: 1 * gb, pid: 2)]
        let (byCPU, byMemory) = ResourceDiagnosis.rankings(cpuPercent: 95, memory: memory(), processes: procs, cores: 8)
        #expect(byCPU.map(\.name) == ["a", "b", ResourceDiagnosis.residualName])
        #expect(byCPU.last?.cpuPercent == 0)
        #expect(byMemory.last?.residentBytes == 0)
        let many = (1...3).map { usage("p\($0)", cpu: 300, bytes: 3 * gb, pid: Int32($0)) }
        let e = ResourceDiagnosis.rankings(cpuPercent: 95, memory: memory(), processes: many, cores: 8).byCPU
        #expect(e.last?.pid == ResourceDiagnosis.residualPid)
    }

    private let sec: UInt64 = 1_000_000_000

    @Test func swapBaselineIsLowestOfLastThirtySeconds() {
        var history = SwapHistory()
        #expect(history.baseline(recording: 500 * mb, now: 0) == nil)
        #expect(history.baseline(recording: 100 * mb, now: 10 * sec) == 500 * mb)
        #expect(history.baseline(recording: 300 * mb, now: 20 * sec) == 100 * mb)
        // The 500 MB reading is older than 30 s here; 100 MB (at 10 s) is the lowest still in the window.
        #expect(history.baseline(recording: 300 * mb, now: 31 * sec) == 100 * mb)
        #expect(history.baseline(recording: 300 * mb, now: 41 * sec) == 300 * mb)
    }

    // MARK: Swarms

    private func members(_ count: Int, family: String, cpu: Double, bytes: UInt64) -> [ProcessUsage] {
        (0..<count).map { usage("m\($0)", cpu: cpu, bytes: bytes, family: family, pid: Int32($0 + 1)) }
    }

    @Test func swarmNeedsFiveMembers() {
        let four = members(4, family: "node", cpu: 50, bytes: 1 * gb)
        #expect(ResourceDiagnosis.swarms(in: four).isEmpty)
        let five = members(5, family: "node", cpu: 50, bytes: 1 * gb)
        #expect(ResourceDiagnosis.swarms(in: five).count == 1)
    }

    @Test func swarmNeedsSizeOrCPU() {
        let tiny = members(6, family: "node", cpu: 1, bytes: 10 * mb)
        #expect(ResourceDiagnosis.swarms(in: tiny).isEmpty)
        let heavyCPU = members(5, family: "node", cpu: 2, bytes: 10 * mb)
        #expect(ResourceDiagnosis.swarms(in: heavyCPU).first?.cpuPercent == 10)
        let heavyMem = members(5, family: "node", cpu: 0, bytes: gb / 4)
        #expect(ResourceDiagnosis.swarms(in: heavyMem).first?.residentBytes == gb / 4 * 5)
        let justUnder = members(5, family: "node", cpu: 1.9, bytes: gb / 5 - 1)
        #expect(ResourceDiagnosis.swarms(in: justUnder).isEmpty)
    }

    @Test func swarmsAreTitledByFamilyAndCount() {
        let procs = members(34, family: ResourceDiagnosis.mcpFamily, cpu: 0.3, bytes: 70 * mb)
        let swarms = ResourceDiagnosis.swarms(in: procs)
        #expect(swarms.first?.count == 34)
        #expect(LoadFormat.swarmTitle(swarms[0]) == "34 MCP processes")
    }

    // MARK: Family

    @Test func mcpFamilyFromArgv() {
        #expect(ResourceDiagnosis.family(name: "node", argv: ["node", "/x/mcp/server.js"]) == ResourceDiagnosis.mcpFamily)
        #expect(ResourceDiagnosis.family(name: "npx", argv: ["npx", "-y", "@x/mcp-server"]) == ResourceDiagnosis.mcpFamily)
        #expect(ResourceDiagnosis.family(name: "uvx", argv: ["uvx", "MCP-fetch"]) == ResourceDiagnosis.mcpFamily)
        #expect(ResourceDiagnosis.family(name: "node", argv: ["node", "app.js"]) == "node")
        #expect(ResourceDiagnosis.family(name: "Xcode", argv: nil) == "Xcode")
    }

    @Test func nativeMCPBinaryIsMCPFamily() {
        #expect(ResourceDiagnosis.family(name: "github-mcp-server", argv: nil) == ResourceDiagnosis.mcpFamily)
        #expect(ResourceDiagnosis.family(name: "MCPHost", argv: nil) == ResourceDiagnosis.mcpFamily)
    }

    @Test func interpreterMatchIsCaseInsensitive() {
        #expect(ResourceDiagnosis.isInterpreter("Python"))
        #expect(ResourceDiagnosis.isInterpreter("Node"))
    }

    @Test func interpreterNames() {
        for name in ["node", "python3", "python3.12", "uv", "uvx", "npx", "bun", "deno"] {
            #expect(ResourceDiagnosis.isInterpreter(name), "\(name)")
        }
        #expect(!ResourceDiagnosis.isInterpreter("Xcode"))
    }

    // MARK: Formatting

    @Test func formatting() {
        #expect(LoadFormat.percent(33.6) == "34%")
        #expect(LoadFormat.percent(182.2) == "182%")
        #expect(LoadFormat.bytes(UInt64(4.1 * Double(gb))) == "4.1 GB")
        #expect(LoadFormat.bytes(512 * mb) == "512 MB")
        #expect(LoadFormat.memory(used: UInt64(18.2 * Double(gb)), total: 36 * gb) == "18.2 of 36 GB")
        #expect(LoadFormat.bytes(2 * gb) == "2 GB")
    }

    @Test func usedFractionClamps() {
        #expect(MemoryReading(usedBytes: 20, totalBytes: 10, swapUsedBytes: 0, pressure: .normal).usedFraction == 1)
        #expect(MemoryReading(usedBytes: 5, totalBytes: 0, swapUsedBytes: 0, pressure: .normal).usedFraction == 0)
    }

    // MARK: Health additions

    @Test func swapGrowthNeedsABaselineAndMoreThan64MB() {
        #expect(!ResourceDiagnosis.isSwapGrowing(swap: gb, baseline: nil))
        #expect(!ResourceDiagnosis.isSwapGrowing(swap: gb + 64 * mb, baseline: gb))
        #expect(ResourceDiagnosis.isSwapGrowing(swap: gb + 65 * mb, baseline: gb))
        #expect(!ResourceDiagnosis.isSwapGrowing(swap: 0, baseline: gb))
    }

    @Test func rankingsKeepEveryProcessAndAddTheResidual() {
        let processes = [usage("a", cpu: 10, bytes: mb, pid: 1), usage("b", cpu: 20, bytes: 2 * mb, pid: 2)]
        let (byCPU, byMemory) = ResourceDiagnosis.rankings(cpuPercent: 50, memory: memory(), processes: processes, cores: 4)
        #expect(byCPU.count == 3 && byMemory.count == 3)
        #expect(byCPU.first?.pid == ResourceDiagnosis.residualPid)
        #expect(byCPU.first?.cpuPercent == 170)
    }

    @Test func processCPUCarriesTheParentPid() {
        let before = ProcessSample(pid: 7, name: "x", family: "x", cpuTimeNs: 0, residentBytes: 1, parentPid: 3)
        let result = ResourceDiagnosis.processCPU(previous: [7: before], current: [before], interval: 2)
        #expect(result.first?.parentPid == 3)
    }
}
