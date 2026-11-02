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

    // MARK: Triggers

    @Test func cpuTriggerBoundary() {
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 89, memory: memory(), swapBaseline: 0, processes: []) == nil)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 90, memory: memory(), swapBaseline: 0, processes: [])?.reason == .highCPU)
    }

    @Test func swapGrowthTrigger() {
        let big = ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(swap: 65 * mb), swapBaseline: 0, processes: [])
        #expect(big?.reason == .swapping)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(swap: 10 * mb), swapBaseline: 0, processes: []) == nil)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(swap: 64 * mb), swapBaseline: 0, processes: []) == nil)
    }

    @Test func swapShrinkingOrUnknownBaselineDoesNotTrigger() {
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(swap: 100 * mb), swapBaseline: 500 * mb, processes: []) == nil)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(swap: 9 * gb), swapBaseline: nil, processes: []) == nil)
    }

    @Test func pressureTrigger() {
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(pressure: .warn), swapBaseline: 0, processes: [])?.reason == .memoryPressure)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(pressure: .critical), swapBaseline: 0, processes: [])?.reason == .memoryPressure)
        #expect(ResourceDiagnosis.evaluate(cpuPercent: 10, memory: memory(pressure: .normal), swapBaseline: 0, processes: []) == nil)
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
        let d = ResourceDiagnosis.evaluate(cpuPercent: 95, memory: memory(), swapBaseline: 0, processes: procs)
        #expect(d?.topCPU.map(\.name) == ["b", "d", "c"])
        #expect(d?.topMemory.map(\.name) == ["c", "a", "e"])
    }

    @Test func tiesBreakByNameThenPid() {
        let procs = [usage("b", cpu: 5, pid: 9), usage("a", cpu: 5, pid: 8), usage("a", cpu: 5, pid: 3), usage("c", cpu: 5, pid: 1)]
        let d = ResourceDiagnosis.evaluate(cpuPercent: 20, memory: memory(pressure: .warn), swapBaseline: 0, processes: procs)
        #expect(d?.topCPU.map(\.pid) == [3, 8, 9])
    }

    // MARK: Residual row

    @Test func residualRowCoversWhatTheScanCannotSee() {
        let procs = [usage("app", cpu: 100, bytes: 2 * gb, pid: 1)]
        // 95% of 8 cores = 760; visible 100; residual 660. Used 8 GB; visible 2 GB; residual 6 GB.
        let d = ResourceDiagnosis.evaluate(cpuPercent: 95, memory: memory(), swapBaseline: 0, processes: procs, cores: 8)
        #expect(d?.topCPU.first?.name == ResourceDiagnosis.residualName)
        #expect(d?.topCPU.first?.cpuPercent == 660)
        #expect(d?.topMemory.first?.name == ResourceDiagnosis.residualName)
        #expect(d?.topMemory.first?.residentBytes == 6 * gb)
    }

    @Test func residualClampsAtZeroAndRanksOnlyWhenItWins() {
        let procs = [usage("a", cpu: 900, bytes: 9 * gb, pid: 1), usage("b", cpu: 10, bytes: 1 * gb, pid: 2)]
        let d = ResourceDiagnosis.evaluate(cpuPercent: 95, memory: memory(), swapBaseline: 0, processes: procs, cores: 8)
        #expect(d?.topCPU.map(\.name) == ["a", "b", ResourceDiagnosis.residualName])
        #expect(d?.topCPU.last?.cpuPercent == 0)
        #expect(d?.topMemory.last?.residentBytes == 0)
        let many = (1...3).map { usage("p\($0)", cpu: 300, bytes: 3 * gb, pid: Int32($0)) }
        let e = ResourceDiagnosis.evaluate(cpuPercent: 95, memory: memory(), swapBaseline: 0, processes: many, cores: 8)
        #expect(e?.topCPU.contains { $0.pid == ResourceDiagnosis.residualPid } == false)
    }

    // MARK: Precedence

    @Test func reasonPrecedenceIsCPUThenSwapThenPressure() {
        let all = memory(swap: 200 * mb, pressure: .critical)
        #expect(ResourceDiagnosis.trigger(cpuPercent: 95, memory: all, swapBaseline: 0) == .highCPU)
        #expect(ResourceDiagnosis.trigger(cpuPercent: 10, memory: all, swapBaseline: 0) == .swapping)
        #expect(ResourceDiagnosis.trigger(cpuPercent: 10, memory: all, swapBaseline: 200 * mb) == .memoryPressure)
    }

    // MARK: Hold and swap history

    private let sec: UInt64 = 1_000_000_000

    private func diagnosis(_ reason: DiagnosisReason = .highCPU) -> Diagnosis {
        Diagnosis(reason: reason, topCPU: [], topMemory: [], swarms: [])
    }

    @Test func holdKeepsDiagnosisThroughBriefDipThenDrops() {
        var hold = DiagnosisHold()
        #expect(hold.update(diagnosis(), now: 0) != nil)
        for tick in 1...5 { #expect(hold.update(nil, now: UInt64(tick) * 2 * sec) != nil, "tick \(tick)") }
        #expect(hold.update(nil, now: 12 * sec) == nil)
        #expect(hold.update(nil, now: 14 * sec) == nil)
    }

    @Test func freshTriggerReplacesHeldAndRestartsClock() {
        var hold = DiagnosisHold()
        _ = hold.update(diagnosis(.highCPU), now: 0)
        #expect(hold.update(diagnosis(.swapping), now: 4 * sec)?.reason == .swapping)
        #expect(hold.update(nil, now: 14 * sec)?.reason == .swapping)
        #expect(hold.update(nil, now: 15 * sec) == nil)
    }

    @Test func steadySwapGrowthTriggersWithinThirtySeconds() {
        var history = SwapHistory()
        var triggeredAt: UInt64?
        for tick in 0...15 {
            let now = UInt64(tick) * 2 * sec
            let swap = UInt64(tick) * 40 * mb
            let baseline = history.baseline(recording: swap, now: now)
            if triggeredAt == nil,
                ResourceDiagnosis.trigger(cpuPercent: 10, memory: memory(swap: swap), swapBaseline: baseline) == .swapping
            { triggeredAt = now }
        }
        #expect(triggeredAt != nil && triggeredAt! <= 30 * sec)
    }

    @Test func swapBaselineIsLowestOfLastThirtySeconds() {
        var history = SwapHistory()
        #expect(history.baseline(recording: 500 * mb, now: 0) == nil)
        #expect(history.baseline(recording: 100 * mb, now: 10 * sec) == 500 * mb)
        #expect(history.baseline(recording: 300 * mb, now: 20 * sec) == 100 * mb)
        // The 500 MB reading is older than 30 s here; 100 MB (at 10 s) is the lowest still in the window.
        #expect(history.baseline(recording: 300 * mb, now: 31 * sec) == 100 * mb)
        #expect(history.baseline(recording: 300 * mb, now: 41 * sec) == 300 * mb)
    }

    @Test func swapBurstStaysVisibleThroughHold() {
        var history = SwapHistory()
        var hold = DiagnosisHold()
        _ = history.baseline(recording: 0, now: 0)
        let burst = history.baseline(recording: 100 * mb, now: 2 * sec)
        let reason = ResourceDiagnosis.trigger(cpuPercent: 10, memory: memory(swap: 100 * mb), swapBaseline: burst)
        #expect(reason == .swapping)
        #expect(hold.update(diagnosis(.swapping), now: 2 * sec) != nil)
        // Swap drops back; the trigger is gone but the hold keeps the diagnosis for the next 10 s.
        let back = history.baseline(recording: 0, now: 4 * sec)
        #expect(ResourceDiagnosis.trigger(cpuPercent: 10, memory: memory(swap: 0), swapBaseline: back) == nil)
        #expect(hold.update(nil, now: 4 * sec)?.reason == .swapping)
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

    @Test func swarmsReportedInDiagnosis() {
        let procs = members(34, family: ResourceDiagnosis.mcpFamily, cpu: 0.3, bytes: 70 * mb)
        let d = ResourceDiagnosis.evaluate(cpuPercent: 95, memory: memory(), swapBaseline: 0, processes: procs)
        #expect(d?.swarms.first?.count == 34)
        #expect(LoadFormat.swarmTitle(d!.swarms[0]) == "34 MCP processes")
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
        #expect(LoadFormat.reason(.highCPU) == "CPU above 90%")
        #expect(LoadFormat.reason(.swapping) == "Memory is swapping")
        #expect(LoadFormat.reason(.memoryPressure) == "Memory pressure high")
    }

    @Test func usedFractionClamps() {
        #expect(MemoryReading(usedBytes: 20, totalBytes: 10, swapUsedBytes: 0, pressure: .normal).usedFraction == 1)
        #expect(MemoryReading(usedBytes: 5, totalBytes: 0, swapUsedBytes: 0, pressure: .normal).usedFraction == 0)
    }
}
