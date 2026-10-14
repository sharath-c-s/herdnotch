import Darwin
import Foundation
import HerdKit
import Testing

/// Covers the herdr data layer: wire decoding against real captured payloads, NDJSON framing, session
/// discovery, snapshot assembly and ordering, and the two failure modes that decide whether the panel
/// is usable in practice (a dead session, a stale socket file).
///
/// Written against swift-testing rather than XCTest because this machine has Command Line Tools only:
/// XCTest ships with Xcode, `Testing.framework` ships with the CLT, and the whole point of HerdKit
/// being a SwiftPM package is that its tests run before Xcode is installed.
struct HerdKitTests {

    // MARK: - Wire decoding

    /// The real `agent.list` capture from the `hail_mary` session must decode to the five agents it
    /// contains, with the agent kinds and statuses herdr actually reported.
    @Test func decodesRealAgentList() throws {
        let client = try fixtureClient(methods: ["agent.list": "agent_list"])
        let agents = try client.listAgents()

        #expect(agents.count == 5)
        #expect(agents.map(\.agent) == ["codex", "claude", "claude", "codex", "claude"])
        #expect(agents.map(\.agentStatus) == [.idle, .idle, .idle, .idle, .working])
        #expect(agents.map(\.paneId) == ["w1:pD", "w1:pF", "w1:pN", "w2:p1", "w2:p2"])

        let last = try #require(agents.last)
        #expect(last.workspaceId == "w2")
        #expect(last.tabId == "w2:t2")
        #expect(last.focused)
        #expect(last.cwd == "/Users/dev/playground/boring-herd")
        #expect(last.foregroundCwd == "/Users/dev/.claude/plugins/marketplaces/thedotmack")

        let first = try #require(agents.first)
        #expect(first.terminalId == "term_656f9d8b035783")
        // Identity is the pane id, which SwiftUI relies on to keep rows stable across polls.
        #expect(first.id == "w1:pD")
    }

    /// The real `workspace.list` capture must decode with its labels, numbers and rolled-up statuses,
    /// and with an empty `agents` array since that key is not on the wire at all.
    @Test func decodesRealWorkspaceList() throws {
        let client = try fixtureClient(methods: ["workspace.list": "workspace_list"])
        let workspaces = try client.listWorkspaces()

        #expect(workspaces.map(\.workspaceId) == ["w1", "w2"])
        #expect(workspaces.compactMap(\.label) == ["shara_misc", "shara"])
        #expect(workspaces.map(\.number) == [1, 2])
        #expect(workspaces.map(\.agentStatus) == [.idle, .working])
        #expect(workspaces.map(\.paneCount) == [4, 2])
        #expect(workspaces.map(\.tabCount) == [3, 2])
        #expect(workspaces.map(\.activeTabId) == ["w1:t7", "w2:t2"])
        #expect(workspaces.map(\.focused) == [false, true])
        #expect(workspaces.allSatisfy { $0.agents.isEmpty })
    }

    /// A status string this build has never heard of must decode to `.unknown` instead of throwing. If
    /// it threw, a herdr release that adds a state would blank the whole panel.
    @Test func unknownStatusDecodesToUnknown() throws {
        let payload = Data(
            """
            {"agent":"claude","agent_status":"sleepwalking","cwd":"/tmp","focused":false,
             "pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
            """.utf8
        )
        let agent = try HerdJSON.decoder.decode(HerdAgent.self, from: payload)

        #expect(agent.agentStatus == .unknown)
        #expect(agent.paneId == "w1:p1")
        #expect(agent.foregroundCwd == nil)
        #expect(agent.terminalId == nil)
    }

    /// herdr's fifth agent state has to survive the round trip as itself rather than folding to
    /// `unknown`, which is what this build did before and what cost the panel its completion signal.
    @Test func doneStatusDecodesAsDone() throws {
        let payload = Data(
            """
            {"agent":"claude","agent_status":"done","cwd":"/tmp","focused":false,
             "pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
            """.utf8
        )
        let agent = try HerdJSON.decoder.decode(HerdAgent.self, from: payload)

        #expect(agent.agentStatus == .done)
        // The raw value is the spelling herdr's own serialisation uses, so a rename here would silently
        // stop matching the wire.
        #expect(AgentStatus.done.rawValue == "done")
    }

    // MARK: - Counts

    /// A tally must count every status, `done` included, and its total must account for all of them.
    @Test func countsTallyEveryStatus() {
        let statuses: [AgentStatus] = [.blocked, .done, .done, .working, .idle, .idle, .idle, .unknown]
        let agents = statuses.enumerated().map { index, status in
            HerdAgent(
                agent: "claude",
                agentStatus: status,
                cwd: "/tmp/p\(index)",
                paneId: "w1:p\(index)",
                tabId: "w1:t\(index)",
                workspaceId: "w1"
            )
        }

        let counts = StatusCounts(agents: agents)

        #expect(counts == StatusCounts(blocked: 1, done: 2, working: 1, idle: 3, unknown: 1))
        #expect(counts.total == statuses.count)
    }

    /// A tally encoded before `done` existed must still decode, with `done` reading as zero.
    ///
    /// This is the compatibility case that forced ``StatusCounts`` to spell out its decoder: the
    /// synthesised one throws on a missing key, so adding a field would have made every snapshot written
    /// by an earlier build undecodable.
    @Test func countsDecodeAPayloadWrittenBeforeDoneExisted() throws {
        let payload = Data(#"{"blocked":1,"working":2,"idle":10,"unknown":0}"#.utf8)

        let counts = try HerdJSON.decoder.decode(StatusCounts.self, from: payload)

        #expect(counts == StatusCounts(blocked: 1, done: 0, working: 2, idle: 10, unknown: 0))
        #expect(counts.total == 13)
    }

    // MARK: - Roll-up

    /// Every ordered pair of statuses must roll up to the higher-precedence one, with precedence
    /// `blocked` > `done` > `working` > `idle` > `unknown`, and the operation must be commutative.
    @Test func rollUpPrefersBlocked() {
        let precedence: [AgentStatus] = [.blocked, .done, .working, .idle, .unknown]

        for (leftIndex, left) in precedence.enumerated() {
            for (rightIndex, right) in precedence.enumerated() {
                let expected = precedence[min(leftIndex, rightIndex)]
                #expect(left.rollUp(right) == expected, "\(left).rollUp(\(right))")
                #expect(right.rollUp(left) == expected, "\(right).rollUp(\(left))")
            }
        }
        // Fails if a case is added to AgentStatus without deciding where it sits in the precedence.
        #expect(AgentStatus.allCases.count == precedence.count)
    }

    // MARK: - Framing

    /// The framer must survive both directions of the mismatch between `recv()` boundaries and line
    /// boundaries: several responses in one read, and one response spread over several reads.
    @Test func ndjsonFramingHandlesSplitAndCoalescedReads() throws {
        var framer = NDJSONFramer()

        // Two complete responses arriving in a single read.
        let coalesced = try framer.append(bytes(#"{"id":"a"}"# + "\n" + #"{"id":"b"}"# + "\n"))
        #expect(coalesced.map(text) == [#"{"id":"a"}"#, #"{"id":"b"}"#])
        #expect(framer.pendingByteCount == 0)

        // A line split mid-token buffers until its newline arrives.
        #expect(try framer.append(bytes(#"{"id":"c","re"#)).isEmpty)
        #expect(framer.pendingByteCount == 13)
        #expect(try framer.append(bytes(#"sult":{}}"#)).isEmpty)
        #expect(try framer.append(bytes("\n")).map(text) == [#"{"id":"c","result":{}}"#])
        #expect(framer.pendingByteCount == 0)

        // Blank lines carry no document and must not be surfaced as empty messages.
        #expect(try framer.append(bytes("\n\n\n")).isEmpty)
        #expect(try framer.append(bytes("\n{}\n\n")).map(text) == ["{}"])
        #expect(framer.pendingByteCount == 0)

        // An empty read is a no-op, not an error and not a message.
        #expect(try framer.append(Data()).isEmpty)
    }

    /// A peer that connects and then streams bytes without ever sending a newline must not be able to
    /// drive unbounded allocation for the whole timeout window. The cap applies per line, so a burst
    /// of many small complete responses far exceeding it in total is still accepted.
    @Test func ndjsonFramingRejectsAnUnterminatedLineOverTheCap() throws {
        var framer = NDJSONFramer(maximumLineBytes: 1024)

        // Just under the cap is fine and stays buffered, waiting for its newline.
        #expect(try framer.append(Data(repeating: UInt8(ascii: "x"), count: 1000)).isEmpty)
        #expect(framer.pendingByteCount == 1000)

        // Crossing it is a protocol error, and the buffer is released rather than retained.
        #expect(throws: HerdrError.self) {
            try framer.append(Data(repeating: UInt8(ascii: "x"), count: 200))
        }
        #expect(framer.pendingByteCount == 0)

        // Total bytes well over the cap are fine as long as no single line exceeds it.
        var small = NDJSONFramer(maximumLineBytes: 64)
        let hundredLines = bytes(String(repeating: "{}\n", count: 100))
        #expect(try small.append(hundredLines).count == 100)
        #expect(small.pendingByteCount == 0)
    }

    /// The `timeout` argument must bound the whole call, not each phase separately.
    ///
    /// The connector here burns 0.5 s before returning, and the connection then honours whatever read
    /// timeout it is handed. With one shared deadline the call lands at about 1.0 s. With a per-phase
    /// timeout the read would restart the clock and the call would take about 1.5 s, which is the
    /// regression this test exists to catch: ``HerdSnapshotBuilder`` makes two calls per session per
    /// poll, so the overshoot compounds.
    @Test func callTimeoutIsASingleEndToEndBudget() throws {
        let client = HerdrClient(
            socketPath: "/fake/herdr.sock",
            connector: SlowConnector(connectDelay: 0.5)
        )

        let started = DispatchTime.now().uptimeNanoseconds
        #expect(throws: HerdrError.timeout) {
            _ = try client.call("agent.list", timeout: 1.0)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        #expect(elapsed >= 0.9, "the budget should actually be spent, took \(elapsed)s")
        #expect(elapsed < 1.35, "timeout was per-phase, not end-to-end: took \(elapsed)s")
    }

    // MARK: - Discovery

    /// Discovery must find the default socket plus every `sessions/<name>/herdr.sock`, split them into
    /// running and stopped by whether `connect()` succeeds, and order them running-first with the
    /// default session ahead of alphabetically earlier running sessions.
    @Test func discoversRunningAndStoppedSessions() throws {
        let names = ["aaa_first", "hail_mary", "oncall_20-23_07", "shara_oncall_2-6_07"]
        let root = try makeConfigRoot(named: names)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = socketPath(in: root, session: "shara_oncall_2-6_07")
        var routes: [String: FakeConnector.Route] = [socketPath(in: root): .serving([:])]
        for name in names where name != "shara_oncall_2-6_07" {
            routes[socketPath(in: root, session: name)] = .serving([:])
        }
        routes[stale] = .unreachable

        let sessions = HerdrDiscovery(configRoot: root, connector: FakeConnector(routes: routes)).discover()

        #expect(sessions.map(\.name) == ["default", "aaa_first", "hail_mary", "oncall_20-23_07", "shara_oncall_2-6_07"])
        #expect(sessions.map(\.running) == [true, true, true, true, false])
        #expect(sessions.first?.isDefault == true)
        #expect(sessions.filter(\.isDefault).count == 1)
        // A stopped session keeps its socket path so the panel can retry it without rediscovery.
        #expect(sessions.last?.socketPath == stale)
        #expect(sessions.allSatisfy { $0.workspaces.isEmpty && $0.error == nil })
    }

    // MARK: - Remote discovery

    /// A configured socket path and a configured directory of sockets must both become sessions, must be
    /// flagged remote, must be ordered after the local ones, and must not disturb local discovery.
    ///
    /// The `herdr-client.sock` in the scanned directory is the trap this asserts against: it sits beside every
    /// real socket, it is created by the *server* rather than by a client, and probing it would report a
    /// session that does not exist. Local discovery avoids it by naming `herdr.sock` outright; a directory
    /// scan has to exclude it deliberately.
    @Test func extraPathsBecomeRemoteSessions() throws {
        let root = try makeConfigRoot(named: ["hail_mary"])
        defer { try? FileManager.default.removeItem(at: root) }
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }

        let manager = FileManager.default
        let single = forwarded.appending(path: "lone.sock").path
        let directory = forwarded.appending(path: "tunnels", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let inDirectory = directory.appending(path: "prod_api.sock").path
        let alsoInDirectory = directory.appending(path: "prod_batch.sock").path
        let clientSocket = directory.appending(path: "herdr-client.sock").path
        let notASocket = directory.appending(path: "readme.txt").path
        for path in [single, inDirectory, alsoInDirectory, clientSocket, notASocket] {
            #expect(manager.createFile(atPath: path, contents: nil))
        }

        var routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .serving([:]),
            socketPath(in: root, session: "hail_mary"): .serving([:]),
            single: .serving([:]),
            inDirectory: .serving([:]),
            // Left unreachable, which is what a forward whose far side is gone looks like.
            alsoInDirectory: .unreachable
        ]
        // Reachable, and must still never be discovered.
        routes[clientSocket] = .serving([:])

        let sessions = HerdrDiscovery(
            configRoot: root,
            extraPaths: [single, directory.path],
            connector: FakeConnector(routes: routes)
        ).discover()

        // Running local, running remote, then the unreachable remote last.
        #expect(sessions.map(\.name) == ["default", "hail_mary", "lone", "prod_api", "prod_batch"])
        #expect(sessions.map(\.isRemote) == [false, false, true, true, true])
        #expect(sessions.map(\.running) == [true, true, true, true, false])
        #expect(sessions.first { $0.name == "prod_api" }?.socketPath == inDirectory)
        // Neither the client socket nor the non-socket file may appear.
        #expect(!sessions.contains { $0.socketPath == clientSocket })
        #expect(!sessions.contains { $0.socketPath == notASocket })
    }

    /// A forwarded remote config root is usually mounted as `<dir>/herdr.sock`, which would otherwise show as
    /// a session literally called `herdr`. The containing directory is the name the user chose, so that is the
    /// name to print.
    @Test func aForwardedConfigRootIsNamedAfterItsDirectory() throws {
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }
        let directory = forwarded.appending(path: "prod", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appending(path: "herdr.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: nil))

        let sessions = HerdrDiscovery(
            configRoot: forwarded.appending(path: "absent", directoryHint: .isDirectory),
            extraPaths: [socket],
            connector: FakeConnector(routes: [socket: .serving([:])])
        ).discover()

        #expect(sessions.map(\.name) == ["prod"])
        #expect(sessions.first?.isRemote == true)
    }

    /// A configured path that does not exist has to be reported as a stopped remote session rather than
    /// dropped, because a forward that is down is precisely the case the user needs to see. A session that
    /// silently vanishes cannot be told apart from a broken panel.
    @Test func aMissingExtraPathIsReportedAsStoppedRatherThanDropped() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = "/tmp/herdkit-absent-\(UInt32.random(in: .min ... .max))/prod.sock"

        let sessions = HerdrDiscovery(
            configRoot: root,
            extraPaths: [missing, "   ", ""],
            connector: FakeConnector(routes: [socketPath(in: root): .serving([:])])
        ).discover()

        #expect(sessions.map(\.name) == ["default", "prod"])
        let remote = try #require(sessions.last)
        #expect(remote.isRemote)
        #expect(!remote.running)
        #expect(remote.socketPath == missing)
    }

    /// A remote socket whose derived name collides with a local session must be renamed rather than shadow
    /// it. Names are the session filter's keys and SwiftUI's row identities, so a duplicate would make one
    /// session unselectable and give the list two rows with the same id.
    @Test func aCollidingRemoteNameIsDisambiguated() throws {
        let root = try makeConfigRoot(named: ["hail_mary"])
        defer { try? FileManager.default.removeItem(at: root) }
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }

        let first = forwarded.appending(path: "hail_mary.sock").path
        let nested = forwarded.appending(path: "b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let second = nested.appending(path: "hail_mary.sock").path
        #expect(FileManager.default.createFile(atPath: first, contents: nil))
        #expect(FileManager.default.createFile(atPath: second, contents: nil))

        let sessions = HerdrDiscovery(
            configRoot: root,
            extraPaths: [first, second],
            connector: FakeConnector(routes: [
                socketPath(in: root): .serving([:]),
                socketPath(in: root, session: "hail_mary"): .serving([:]),
                first: .serving([:]),
                second: .serving([:])
            ])
        ).discover()

        #expect(sessions.map(\.name) == ["default", "hail_mary", "hail_mary (2)", "hail_mary (3)"])
        #expect(Set(sessions.map(\.name)).count == sessions.count)
        // The local session keeps the plain name, so an existing session filter keeps meaning what it meant.
        #expect(sessions.first { $0.name == "hail_mary" }?.isRemote == false)
    }

    /// Listing a directory and a socket inside it must not produce the same session twice.
    @Test func anExtraPathListedTwiceIsDiscoveredOnce() throws {
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }
        let socket = forwarded.appending(path: "prod.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: nil))

        let sessions = HerdrDiscovery(
            configRoot: forwarded.appending(path: "absent", directoryHint: .isDirectory),
            extraPaths: [forwarded.path, socket, forwarded.path],
            connector: FakeConnector(routes: [socket: .serving([:])])
        ).discover()

        #expect(sessions.map(\.name) == ["prod"])
    }

    // MARK: - Snapshot assembly

    /// One session failing must cost exactly that session: the others keep their data, and the failed
    /// one keeps its row with an error message rather than vanishing.
    @Test func oneDeadSessionDoesNotFailSnapshot() throws {
        let root = try makeConfigRoot(named: ["healthy", "dead"])
        defer { try? FileManager.default.removeItem(at: root) }

        let serving = FakeConnector.Route.serving([
            "workspace.list": [try Fixture.wireLine("workspace_list")],
            "agent.list": [try Fixture.wireLine("agent_list")]
        ])
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): serving,
            socketPath(in: root, session: "healthy"): serving,
            // Answers the liveness probe, then refuses the data calls.
            socketPath(in: root, session: "dead"): .reachableOnce
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()

        #expect(snapshot.sessions.map(\.name) == ["default", "dead", "healthy"])
        let dead = try #require(snapshot.sessions.first { $0.name == "dead" })
        #expect(dead.error != nil)
        #expect(dead.running)
        #expect(dead.workspaces.isEmpty)

        for name in ["default", "healthy"] {
            let session = try #require(snapshot.sessions.first { $0.name == name })
            #expect(session.error == nil, "\(name)")
            #expect(session.workspaces.map(\.workspaceId) == ["w1", "w2"], "\(name)")
            #expect(session.workspaces.map(\.agents.count) == [3, 2], "\(name)")
            #expect(session.workspaces.compactMap(\.label) == ["shara_misc", "shara"], "\(name)")
        }
        // Counts span every session, so the two healthy ones contribute twelve agents in total.
        #expect(snapshot.counts == StatusCounts(blocked: 0, working: 2, idle: 8, unknown: 0))
        #expect(snapshot.counts.total == 10)
    }

    /// Two remote sessions that accept a connection and then never answer must cost one timeout between
    /// them, not one each, and the local sessions must still arrive fully populated.
    ///
    /// This is the requirement that forced the population pass to fan out instead of being a `map`. A
    /// blackholed `ssh -L` forward is reachable and silent, so it costs its whole call budget; sequentially,
    /// two of them would add both budgets to every snapshot and the local rows would go stale behind them.
    /// The assertion is deliberately a comparison against the sum rather than an absolute figure, so a slow
    /// or loaded machine cannot fail it while the behaviour is right.
    @Test func stalledRemoteSessionsDoNotSumIntoTheBuildTime() throws {
        let root = try makeConfigRoot(named: ["hail_mary", "oncall"])
        defer { try? FileManager.default.removeItem(at: root) }
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }

        let firstStall = forwarded.appending(path: "prod_a.sock").path
        let secondStall = forwarded.appending(path: "prod_b.sock").path
        for path in [firstStall, secondStall] {
            #expect(FileManager.default.createFile(atPath: path, contents: nil))
        }

        let serving = FakeConnector.Route.serving([
            "workspace.list": [try Fixture.wireLine("workspace_list")],
            "agent.list": [try Fixture.wireLine("agent_list")]
        ])
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): serving,
            socketPath(in: root, session: "hail_mary"): serving,
            socketPath(in: root, session: "oncall"): serving,
            firstStall: .stalling,
            secondStall: .stalling
        ]

        let stallBudget: TimeInterval = 0.4
        let builder = HerdSnapshotBuilder(
            configRoot: root,
            extraPaths: [forwarded.path],
            connector: FakeConnector(routes: routes),
            callTimeout: 2.0,
            remoteCallTimeout: stallBudget
        )

        let start = Date()
        let snapshot = builder.build()
        let elapsed = Date().timeIntervalSince(start)

        // Sequentially this would be at least two budgets. Concurrently it is one plus scheduling slop.
        #expect(
            elapsed < stallBudget * 1.8,
            "two stalled remotes took \(elapsed)s against a \(stallBudget)s budget each"
        )
        // And the point of all of it: the local sessions are unaffected in content, not merely in timing.
        for name in ["default", "hail_mary", "oncall"] {
            let session = try #require(snapshot.sessions.first { $0.name == name })
            #expect(session.error == nil, "\(name)")
            #expect(session.workspaces.map(\.agents.count) == [3, 2], "\(name)")
        }
        #expect(snapshot.counts.total == 15)
        // The stalled remotes keep their rows, carrying the reason, rather than vanishing.
        for name in ["prod_a", "prod_b"] {
            let session = try #require(snapshot.sessions.first { $0.name == name })
            #expect(session.isRemote, "\(name)")
            #expect(session.running, "\(name)")
            #expect(session.error != nil, "\(name)")
            #expect(session.workspaces.isEmpty, "\(name)")
        }
    }

    /// A dead forwarded socket must fail exactly the way a stale local one does: refused at connect, so it
    /// is reported as not running and costs no time at all.
    @Test func aDeadForwardedSocketFailsAsFastAsAStaleLocalOne() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let forwarded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forwarded) }
        let dead = forwarded.appending(path: "prod.sock").path
        #expect(FileManager.default.createFile(atPath: dead, contents: nil))

        let snapshot = HerdSnapshotBuilder(
            configRoot: root,
            extraPaths: [dead],
            connector: FakeConnector(routes: [
                socketPath(in: root): .serving([
                    "workspace.list": [try Fixture.wireLine("workspace_list")],
                    "agent.list": [try Fixture.wireLine("agent_list")]
                ]),
                dead: .unreachable
            ])
        ).build()

        let remote = try #require(snapshot.sessions.first { $0.name == "prod" })
        #expect(remote.isRemote)
        #expect(!remote.running)
        #expect(remote.error == nil)
        #expect(remote.workspaces.isEmpty)
        // The local session is untouched, which is the other half of "one bad remote costs one row".
        #expect(snapshot.counts.total == 5)
    }

    /// Agents must arrive from the builder already sorted blocked first, then working, then unknown,
    /// then idle, with equal statuses broken by `cwd`, so no view ever re-sorts.
    @Test func agentsSortBlockedFirst() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceLine = try responseLine([
            "type": "workspace_list",
            "workspaces": [
                ["workspace_id": "w1", "number": 1, "label": "solo", "focused": true, "agent_status": "blocked"]
            ]
        ])
        let agentLine = try responseLine([
            "type": "agent_list",
            "agents": [
                agentJSON(paneId: "p1", status: "idle", cwd: "/b"),
                agentJSON(paneId: "p2", status: "unknown", cwd: "/a"),
                agentJSON(paneId: "p3", status: "working", cwd: "/z"),
                agentJSON(paneId: "p4", status: "blocked", cwd: "/m"),
                agentJSON(paneId: "p5", status: "idle", cwd: "/a"),
                agentJSON(paneId: "p6", status: "working", cwd: "/a")
            ]
        ])
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .serving([
                "workspace.list": [workspaceLine],
                "agent.list": [agentLine]
            ])
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()

        let workspace = try #require(snapshot.sessions.first?.workspaces.first)
        #expect(workspace.agents.map(\.agentStatus) == [.blocked, .working, .working, .unknown, .idle, .idle])
        #expect(workspace.agents.map(\.cwd) == ["/m", "/a", "/z", "/a", "/a", "/b"])
        #expect(snapshot.counts == StatusCounts(blocked: 1, working: 2, idle: 2, unknown: 1))
    }

    /// Tab labels from `tab.list` must join onto agents by `tab_id`, and an agent whose tab is missing
    /// from the reply must keep its row with a nil label rather than being dropped: `agent.list` and
    /// `tab.list` are separate round trips, so a tab created between them is legitimately absent.
    @Test func tabLabelsJoinOntoAgentsByTabId() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceLine = try responseLine([
            "type": "workspace_list",
            "workspaces": [
                ["workspace_id": "w1", "number": 1, "label": "solo", "focused": true, "agent_status": "idle"]
            ]
        ])
        let agentLine = try responseLine([
            "type": "agent_list",
            "agents": [
                agentJSON(paneId: "p1", status: "idle", cwd: "/a", tabId: "w1:t1"),
                agentJSON(paneId: "p2", status: "idle", cwd: "/b", tabId: "w1:t2"),
                // Shares a tab with p1: two agents in one tab legitimately show the same label.
                agentJSON(paneId: "p3", status: "idle", cwd: "/c", tabId: "w1:t1"),
                // Tab created after `tab.list` was answered, so it has no entry.
                agentJSON(paneId: "p4", status: "idle", cwd: "/d", tabId: "w1:tZ")
            ]
        ])
        let tabLine = try responseLine([
            "type": "tab_list",
            "tabs": [
                ["tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "catalog_version_diff",
                 "focused": false, "pane_count": 2, "agent_status": "idle"],
                // An empty label is treated as no label, same as a lookup miss.
                ["tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": "",
                 "focused": false, "pane_count": 1, "agent_status": "idle"]
            ]
        ])
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .serving([
                "workspace.list": [workspaceLine],
                "agent.list": [agentLine],
                "tab.list": [tabLine]
            ])
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()
        let workspace = try #require(snapshot.sessions.first?.workspaces.first)

        // Every agent survives the join, in the usual cwd order.
        #expect(workspace.agents.map(\.paneId) == ["p1", "p2", "p3", "p4"])
        #expect(workspace.agents.map(\.tabLabel) == ["catalog_version_diff", nil, "catalog_version_diff", nil])
        #expect(snapshot.sessions.first?.error == nil)
    }

    /// `tab.list` failing is cosmetic: the session keeps its agents with nil labels and stays healthy,
    /// because the row falls back to the cwd basename and an error row would overstate the problem.
    @Test func failingTabListLeavesAgentsUnlabelledNotErrored() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        // No `tab.list` entry, so that call gets an immediate EOF, which is what a server that has
        // dropped the connection looks like.
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .serving([
                "workspace.list": [try Fixture.wireLine("workspace_list")],
                "agent.list": [try Fixture.wireLine("agent_list")]
            ])
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()
        let session = try #require(snapshot.sessions.first)

        #expect(session.error == nil, "a cosmetic tab.list failure must not error the session")
        #expect(session.workspaces.map(\.agents.count) == [3, 2])
        let agents = session.workspaces.flatMap(\.agents)
        #expect(agents.allSatisfy { $0.tabLabel == nil })
        #expect(snapshot.counts.total == 5)
    }

    /// `workspace.list` failing must cost the session its grouping labels, not its rows.
    ///
    /// It used to sit inside the same fatal path as `agent.list`, so a transient fault on the call that only
    /// says what the workspaces are *called* replaced every agent with an error line. The agents are the
    /// reason the panel exists; the workspace label is furniture around them.
    @Test func aFailingWorkspaceListKeepsTheAgentRows() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        // No `workspace.list` entry, so that call gets an immediate EOF: a server that dropped the
        // connection.
        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .serving(["agent.list": [try Fixture.wireLine("agent_list")]])
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()
        let session = try #require(snapshot.sessions.first)

        #expect(session.error == nil, "a workspace.list failure must not erase the rows")
        #expect(snapshot.counts.total == 5)
        // Grouped under synthesised placeholders, which print the workspace id rather than its label.
        #expect(session.workspaces.allSatisfy { $0.label == nil })
        #expect(session.workspaces.flatMap(\.agents).count == 5)
    }

    /// A one-shot socket fault on `agent.list` must be retried rather than erasing the session.
    ///
    /// This is the blast-radius half of the `setsockopt(SO_RCVTIMEO)` report: a single fault against a server
    /// that was answering a second earlier took out all of that session's rows. Every call opens a fresh
    /// connection, so asking again is a genuinely different attempt.
    @Test func aOneShotFaultOnAgentListIsRetriedRatherThanErasingTheSession() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let routes: [String: FakeConnector.Route] = [
            socketPath(in: root): .faultingFirstRequest(
                method: "agent.list",
                table: [
                    "workspace.list": [try Fixture.wireLine("workspace_list")],
                    "agent.list": [try Fixture.wireLine("agent_list")]
                ]
            )
        ]

        let snapshot = HerdSnapshotBuilder(configRoot: root, connector: FakeConnector(routes: routes)).build()
        let session = try #require(snapshot.sessions.first)

        #expect(session.error == nil, "a retriable fault erased the session: \(session.error ?? "")")
        #expect(session.workspaces.map(\.agents.count) == [3, 2])
        #expect(snapshot.counts.total == 5)
    }

    /// A timeout is not retried, because it has already spent the budget it would need.
    ///
    /// The distinction is the whole of the retry policy: retrying a fault that cost nothing is free, and
    /// retrying a server that is simply not answering would double the worst case and stall the poll.
    @Test func aStalledSessionIsNotRetriedIntoASecondBudget() throws {
        let root = try makeConfigRoot(named: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let budget: TimeInterval = 0.3
        let builder = HerdSnapshotBuilder(
            configRoot: root,
            connector: FakeConnector(routes: [socketPath(in: root): .stalling]),
            callTimeout: budget
        )

        let start = Date()
        let snapshot = builder.build()
        let elapsed = Date().timeIntervalSince(start)

        #expect(snapshot.sessions.first?.error != nil)
        #expect(elapsed < budget * 1.8, "a stalled session was retried into a second budget: \(elapsed)s")
    }

    /// Raw `agent.list` bytes carry no `tab_label`, so decoding must default it to nil rather than
    /// throwing. This is what makes the new field additive against every existing fixture.
    @Test func agentDecodesWithoutTabLabel() throws {
        let client = try fixtureClient(methods: ["agent.list": "agent_list"])
        let agents = try client.listAgents()
        #expect(!agents.isEmpty)
        #expect(agents.allSatisfy { $0.tabLabel == nil })
    }

    // MARK: - Errors

    /// herdr's real error envelope for an unknown method must surface as `.server` with herdr's own
    /// code, not as a decode failure, so the UI can tell "we asked wrongly" from "we cannot parse".
    @Test func serverErrorEnvelopeMapsToServerError() throws {
        let client = try fixtureClient(methods: ["nope.nope": "error_unknown_method"])

        let error = try #require(throws: HerdrError.self) {
            _ = try client.call("nope.nope")
        }
        guard case .server(let code, let message) = error else {
            Issue.record("expected .server, got \(error)")
            return
        }
        #expect(code == "invalid_request")
        #expect(message.contains("unknown variant"), "\(message)")
        #expect(error.description.hasPrefix("herdr error invalid_request:"))
    }

    /// Connecting to a stale socket file, which is what every stopped session leaves behind, must fail
    /// promptly rather than block. This is the behaviour the whole poll loop depends on: with several
    /// sessions probed every second, one hanging connect would freeze the panel.
    @Test func staleSocketDoesNotHang() throws {
        // Deliberately short and not under NSTemporaryDirectory(): `sockaddr_un.sun_path` holds only
        // 104 bytes and the per-process temporary directory alone is close to that.
        let path = "/tmp/herdkit-stale-\(UInt32.random(in: .min ... .max)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeStaleSocketFile(at: path)
        #expect(FileManager.default.fileExists(atPath: path))

        // Run off the test thread with a hard ceiling so a regression fails the test instead of
        // wedging the whole suite.
        let elapsed = Box<TimeInterval>(.infinity)
        let threw = Box(false)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let start = Date()
            do {
                _ = try UnixSocketConnector().connect(path: path, timeout: 2.0)
            } catch {
                threw.value = true
            }
            elapsed.value = Date().timeIntervalSince(start)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 5) == .success, "connect to a stale socket hung")
        #expect(threw.value, "connect to a stale socket unexpectedly succeeded")
        #expect(elapsed.value < 1.0, "connect to a stale socket took \(elapsed.value)s")
    }

    // MARK: - Socket options against a real socket

    /// A server that answers and then closes must still deliver the answer it already wrote.
    ///
    /// This is the reproduction of the `setsockopt(SO_RCVTIMEO) failed: Invalid argument` the panel printed
    /// in place of a whole session's rows. Darwin's `sosetopt()` refuses **every** socket option once a
    /// socket is fully shut down, and a Unix stream socket becomes fully shut down the instant its peer
    /// closes, because `soisdisconnected()` raises `SS_CANTRCVMORE` and `SS_CANTSENDMORE` together. It
    /// reports that refusal as `EINVAL`, so the per-read `SO_RCVTIMEO` install failed and the response
    /// sitting in the receive buffer was thrown away as though the socket had never worked.
    ///
    /// Intermittent in the live app for exactly the reason the timing here is explicit: whether the peer's
    /// `FIN` is processed before or after the client reaches `read()` is a race, which is why a warm run
    /// succeeded and a cold launch competing with startup did not.
    @Test func aPeerThatClosesAfterAnsweringStillDeliversItsResponse() throws {
        let path = "/tmp/herdkit-closing-\(UInt32.random(in: .min ... .max)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let line = try Fixture.wireLine("agent_list")
        let closed = try startOneShotServer(at: path, answering: line)

        let connection = try UnixSocketConnector().connect(path: path, timeout: 2.0)
        defer { connection.close() }
        try connection.write(Data("{\"id\":\"x\",\"method\":\"agent.list\",\"params\":{}}\n".utf8))
        // Waiting for the server to have closed is what makes the race deterministic rather than lucky.
        #expect(closed.wait(timeout: .now() + 5) == .success, "the one-shot server never closed")

        let chunk = try connection.read(timeout: 2.0)
        #expect(!chunk.isEmpty, "the response the peer already wrote was lost")
    }

    /// An exhausted budget has to present as a timeout, decided before any syscall.
    ///
    /// `HerdrClient` hands each phase `Deadline.remaining`, so a call whose connect and write consumed the
    /// whole budget reaches the read phase with nothing left. The response is deliberately already waiting
    /// in the receive buffer here, because that is what separates a real short-circuit from a clamp: a
    /// clamped budget quietly buys a millisecond the caller never granted and returns the bytes, so only a
    /// read that reports a timeout *despite* readable data has actually honoured the deadline. Passing the
    /// unclamped value through instead would be rejected by the kernel with `EDOM`, which would surface as
    /// `socketUnavailable` rather than as the timeout the contract promises.
    @Test func anExhaustedBudgetReadsAsATimeout() throws {
        let path = "/tmp/herdkit-exhausted-\(UInt32.random(in: .min ... .max)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let closed = try startOneShotServer(at: path, answering: try Fixture.wireLine("agent_list"))

        let connection = try UnixSocketConnector().connect(path: path, timeout: 2.0)
        defer { connection.close() }
        #expect(closed.wait(timeout: .now() + 5) == .success, "the one-shot server never answered")

        for budget in [TimeInterval(0), -1, -0.0001] {
            #expect(throws: HerdrError.timeout) { _ = try connection.read(timeout: budget) }
        }
        // And the same connection still reads normally once it is given a budget, so the short-circuit is a
        // decision about the deadline rather than a broken connection.
        #expect(!(try connection.read(timeout: 2.0)).isEmpty)
    }

    /// The same guarantee one level up: a call whose budget is spent in its earlier phases reports a
    /// timeout, and never hands a non-positive budget down to the read phase.
    @Test func aCallWhoseBudgetIsSpentBeforeTheReadReportsATimeout() throws {
        let client = HerdrClient(
            socketPath: "/fake/herdr.sock",
            connector: SlowConnector(connectDelay: 5.0)
        )
        #expect(throws: HerdrError.timeout) { _ = try client.call("agent.list", timeout: 0.05) }
    }

    // MARK: - Helpers

    /// Starts a server that accepts exactly one connection, writes `response` if there is one, and closes.
    ///
    /// A real listening socket rather than a fake, because the behaviour under test is the kernel's: no
    /// ``SocketConnecting`` double can reproduce what `sosetopt()` does to a shut-down socket.
    ///
    /// - Parameters:
    ///   - path: Where to bind. Must be short enough for `sockaddr_un.sun_path`.
    ///   - response: Bytes to write before closing, or `nil` to accept and hold the connection open.
    /// - Returns: A semaphore signalled once the server has closed its end of the accepted connection, or
    ///   immediately after the accept when `response` is `nil`.
    /// - Throws: A `#require` failure if the socket cannot be bound or listened on.
    private func startOneShotServer(at path: String, answering response: Data?) throws -> DispatchSemaphore {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(listener, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind() failed: \(String(cString: strerror(errno)))")
        try #require(listen(listener, 1) == 0, "listen() failed: \(String(cString: strerror(errno)))")

        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let accepted = accept(listener, nil, nil)
            if accepted >= 0, let response {
                _ = response.withUnsafeBytes { raw in
                    send(accepted, raw.baseAddress, raw.count, 0)
                }
                Darwin.close(accepted)
            }
            closed.signal()
            // Held open for the `nil` case so the client's connection stays connected while it is used.
            if response == nil, accepted >= 0 {
                Thread.sleep(forTimeInterval: 5)
                Darwin.close(accepted)
            }
            Darwin.close(listener)
        }
        return closed
    }

    /// A client whose socket replays fixtures, keyed by the method that should return each one.
    private func fixtureClient(methods: [String: String]) throws -> HerdrClient {
        let path = "/tmp/herdkit-fixture.sock"
        let table = try methods.mapValues { name in [try Fixture.wireLine(name)] }
        return HerdrClient(socketPath: path, connector: FakeConnector(routes: [path: .serving(table)]))
    }

    /// Creates a unique temporary directory. Callers remove it.
    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "herdkit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a herdr-shaped config root: a default `herdr.sock` plus one directory and socket file per
    /// named session. The files only need to exist; liveness comes from the fake connector.
    private func makeConfigRoot(named names: [String]) throws -> URL {
        let root = try makeTemporaryDirectory()
        let manager = FileManager.default
        #expect(manager.createFile(atPath: socketPath(in: root), contents: nil))
        for name in names {
            let directory = root.appending(path: "sessions/\(name)", directoryHint: .isDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(manager.createFile(atPath: socketPath(in: root, session: name), contents: nil))
            // A sibling client socket that discovery must ignore.
            #expect(manager.createFile(atPath: directory.appending(path: "herdr-client.sock").path, contents: nil))
        }
        return root
    }

    /// Path of a session's server socket inside a config root. Omit `session` for the default session.
    private func socketPath(in root: URL, session: String? = nil) -> String {
        guard let session else { return root.appending(path: "herdr.sock").path }
        return root.appending(path: "sessions/\(session)/herdr.sock").path
    }

    /// Leaves behind exactly what a stopped herdr server leaves: a bound `AF_UNIX` socket file with
    /// nothing listening on it.
    private func makeStaleSocketFile(at path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)
        #expect(bound == 0, "bind() failed: \(String(cString: strerror(errno)))")
    }

    /// One agent object in herdr's snake_case wire shape.
    private func agentJSON(
        paneId: String,
        status: String,
        cwd: String,
        tabId: String = "w1:t1"
    ) -> [String: Any] {
        [
            "agent": "claude",
            "agent_status": status,
            "cwd": cwd,
            "foreground_cwd": cwd,
            "focused": false,
            "pane_id": paneId,
            "tab_id": tabId,
            "workspace_id": "w1",
            "terminal_id": "term_\(paneId)",
            "revision": 0
        ]
    }

    /// Wraps a result payload in a success envelope and terminates it as one wire line.
    private func responseLine(_ result: [String: Any]) throws -> Data {
        var line = try JSONSerialization.data(withJSONObject: ["id": "fix", "result": result])
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// UTF-8 bytes of a string, standing in for one `recv()` worth of socket traffic.
    private func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Renders a framed line as text for readable assertion failures.
    private func text(_ line: Data) -> String {
        String(decoding: line, as: UTF8.self)
    }
}
