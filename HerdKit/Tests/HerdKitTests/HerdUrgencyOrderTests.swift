import Foundation
import HerdKit
import Testing

/// Tests for the urgency ordering.
///
/// Everything here is deliberately clock-free: ``HerdUrgencyOrder`` takes the recency decision as a set of
/// keys rather than making it, which is the whole reason the recency memory lives in the app's model layer.
/// That split is what makes these tests deterministic instead of needing a sleep.
@Suite("HerdUrgencyOrder")
struct HerdUrgencyOrderTests {

    /// Builds one agent.
    ///
    /// - Parameters:
    ///   - pane: Pane number, which becomes `w<workspace>:p<pane>`.
    ///   - workspace: Workspace number, which becomes the workspace id.
    ///   - status: The agent's status.
    ///   - label: Tab label, defaulting to a name derived from the pane id.
    /// - Returns: An agent suitable for a fixture snapshot.
    private func agent(
        pane: Int,
        workspace: Int = 1,
        status: AgentStatus,
        label: String? = nil
    ) -> HerdAgent {
        HerdAgent(
            agent: "claude",
            agentStatus: status,
            cwd: "/tmp/w\(workspace)p\(pane)",
            paneId: "w\(workspace):p\(pane)",
            tabId: "w\(workspace):t\(pane)",
            workspaceId: "w\(workspace)",
            tabLabel: label ?? "tab_\(workspace)_\(pane)"
        )
    }

    /// Builds one workspace around a list of agents.
    ///
    /// - Parameters:
    ///   - number: Workspace number, used for both the id and the ordering hint.
    ///   - agents: The agents inside it.
    /// - Returns: A workspace whose rolled-up status is folded from its agents.
    private func workspace(number: Int, agents: [HerdAgent]) -> HerdWorkspace {
        HerdWorkspace(
            workspaceId: "w\(number)",
            label: "ws\(number)",
            number: number,
            agentStatus: agents.reduce(AgentStatus.unknown) { $0.rollUp($1.agentStatus) },
            agents: agents
        )
    }

    /// Builds one session.
    ///
    /// - Parameters:
    ///   - name: Session name.
    ///   - running: Whether the session's server answered.
    ///   - workspaces: The workspaces inside it.
    /// - Returns: A session suitable for a fixture snapshot.
    private func session(
        name: String,
        running: Bool = true,
        workspaces: [HerdWorkspace] = []
    ) -> HerdSession {
        HerdSession(
            name: name,
            isDefault: name == "default",
            running: running,
            socketPath: "/tmp/\(name).sock",
            workspaces: workspaces
        )
    }

    /// Wraps sessions into a snapshot with matching counts.
    ///
    /// - Parameter sessions: The sessions to include.
    /// - Returns: A snapshot with a tally over every agent.
    private func snapshot(_ sessions: [HerdSession]) -> HerdSnapshot {
        HerdSnapshot(
            sessions: sessions,
            counts: StatusCounts(agents: sessions.flatMap { $0.workspaces.flatMap(\.agents) })
        )
    }

    // MARK: Rank

    @Test("blocked outranks done outranks recently completed outranks working outranks unknown outranks idle")
    func rankOrder() {
        #expect(HerdUrgency.blocked < HerdUrgency.done)
        #expect(HerdUrgency.done < HerdUrgency.recentlyCompleted)
        #expect(HerdUrgency.recentlyCompleted < HerdUrgency.working)
        #expect(HerdUrgency.working < HerdUrgency.unknown)
        #expect(HerdUrgency.unknown < HerdUrgency.idle)
    }

    @Test("an agent herdr reports as done ranks done, and the recency set does not enter into it")
    func doneRank() {
        let finished = agent(pane: 1, status: .done)
        let key = HerdUrgencyOrder.key(sessionName: "s", paneId: finished.paneId)

        // Both directions, because `done` is exact and must not depend on whether the app's clock-driven
        // recency memory happens to be holding this pane as well.
        #expect(
            HerdUrgencyOrder.urgency(of: finished, sessionName: "s", recentlyCompleted: [])
                == .done
        )
        #expect(
            HerdUrgencyOrder.urgency(of: finished, sessionName: "s", recentlyCompleted: [key])
                == .done
        )
    }

    @Test("the session holding the done agent outranks a session that is merely working")
    func doneSessionOutranksWorkingSession() {
        let busy = session(name: "busy", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .working)]),
        ])
        let finished = session(name: "finished", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .done)]),
        ])

        let ordered = HerdUrgencyOrder.applying(
            recentlyCompleted: [],
            to: snapshot([busy, finished])
        )

        #expect(ordered.sessions.map(\.name) == ["finished", "busy"])
        #expect(ordered.counts.done == 1)
        #expect(ordered.counts.working == 1)
    }

    @Test("an idle agent in the recency set ranks as recently completed, and outranks working")
    func recentlyCompletedRank() {
        let finished = agent(pane: 1, status: .idle)
        let key = HerdUrgencyOrder.key(sessionName: "s", paneId: finished.paneId)

        #expect(
            HerdUrgencyOrder.urgency(of: finished, sessionName: "s", recentlyCompleted: [key])
                == .recentlyCompleted
        )
        #expect(
            HerdUrgencyOrder.urgency(of: finished, sessionName: "s", recentlyCompleted: [])
                == .idle
        )
        // The same pane id in a different session must not match: pane ids are unique only per session.
        #expect(
            HerdUrgencyOrder.urgency(of: finished, sessionName: "other", recentlyCompleted: [key])
                == .idle
        )
    }

    @Test("a blocked agent in the recency set is still ranked blocked")
    func blockedBeatsRecency() {
        let stuck = agent(pane: 1, status: .blocked)
        let key = HerdUrgencyOrder.key(sessionName: "s", paneId: stuck.paneId)
        #expect(
            HerdUrgencyOrder.urgency(of: stuck, sessionName: "s", recentlyCompleted: [key])
                == .blocked
        )
    }

    // MARK: Hierarchical sort

    @Test("the session holding the blocked agent floats to the top, and its group stays intact")
    func sessionsOrderByMostUrgentMember() {
        let quiet = session(name: "quiet", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .idle), agent(pane: 2, status: .idle)])
        ])
        let busy = session(name: "busy", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .idle)]),
            workspace(number: 2, agents: [
                agent(pane: 1, workspace: 2, status: .idle),
                agent(pane: 2, workspace: 2, status: .blocked)
            ])
        ])

        let ordered = HerdUrgencyOrder.applying(
            recentlyCompleted: [],
            to: snapshot([quiet, busy])
        )

        #expect(ordered.sessions.map(\.name) == ["busy", "quiet"])
        // The workspace holding the blocked agent leads its session, and the blocked agent leads it.
        #expect(ordered.sessions[0].workspaces.map(\.workspaceId) == ["w2", "w1"])
        #expect(ordered.sessions[0].workspaces[0].agents[0].agentStatus == .blocked)
        // Grouping is preserved: every agent in a workspace is still in that workspace, so the ledger's
        // session and workspace elision cannot be interleaved into noise.
        #expect(ordered.sessions[0].workspaces[0].agents.count == 2)
        #expect(ordered.sessions[1].workspaces[0].agents.count == 2)
    }

    @Test("a recently completed agent floats above a working one, across sessions and within a workspace")
    func recencyFloats() {
        let working = session(name: "aaa_working", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .working)])
        ])
        let finished = session(name: "zzz_finished", workspaces: [
            workspace(number: 1, agents: [
                agent(pane: 1, status: .idle, label: "still_idle"),
                agent(pane: 2, status: .idle, label: "just_finished")
            ])
        ])
        let key = HerdUrgencyOrder.key(sessionName: "zzz_finished", paneId: "w1:p2")

        let ordered = HerdUrgencyOrder.applying(
            recentlyCompleted: [key],
            to: snapshot([working, finished])
        )

        #expect(ordered.sessions.map(\.name) == ["zzz_finished", "aaa_working"])
        #expect(ordered.sessions[0].workspaces[0].agents.map(\.tabLabel) == ["just_finished", "still_idle"])
    }

    @Test("stopped sessions sort last even though a running all-idle session outranks nothing")
    func stoppedLast() {
        let stopped = session(name: "aaa_stopped", running: false)
        let idle = session(name: "zzz_idle", workspaces: [
            workspace(number: 1, agents: [agent(pane: 1, status: .idle)])
        ])

        let ordered = HerdUrgencyOrder.applying(
            recentlyCompleted: [],
            to: snapshot([stopped, idle])
        )

        #expect(ordered.sessions.map(\.name) == ["zzz_idle", "aaa_stopped"])
        // Still present. A session that vanishes when its server stops is indistinguishable from a
        // broken panel.
        #expect(ordered.sessions.count == 2)
    }

    // MARK: Stability

    @Test("equal ranks keep their input order, so rows cannot shuffle between polls")
    func stableForEqualRanks() {
        // Sixteen all-idle agents across four sessions: the normal day, and the case where every single
        // comparison is a tie, which is exactly where an unstable sort would show.
        let sessions = (1...4).map { index in
            session(name: "s\(index)", workspaces: [
                workspace(number: 1, agents: (1...4).map { agent(pane: $0, status: .idle) })
            ])
        }
        let input = snapshot(sessions)

        let first = HerdUrgencyOrder.applying(recentlyCompleted: [], to: input)
        let second = HerdUrgencyOrder.applying(recentlyCompleted: [], to: first)
        let third = HerdUrgencyOrder.applying(recentlyCompleted: [], to: second)

        let names = { (snapshot: HerdSnapshot) in
            snapshot.sessions.flatMap { session in
                session.workspaces.flatMap(\.agents).map { "\(session.name)/\($0.paneId)" }
            }
        }

        #expect(names(first) == names(input))
        #expect(names(second) == names(first))
        #expect(names(third) == names(first))
    }

    @Test("counts are carried through untouched")
    func countsPreserved() {
        let input = snapshot([
            session(name: "s", workspaces: [
                workspace(number: 1, agents: [
                    agent(pane: 1, status: .blocked),
                    agent(pane: 2, status: .idle),
                    agent(pane: 3, status: .working)
                ])
            ])
        ])

        let ordered = HerdUrgencyOrder.applying(recentlyCompleted: [], to: input)

        #expect(ordered.counts.blocked == 1)
        #expect(ordered.counts.working == 1)
        #expect(ordered.counts.idle == 1)
        #expect(ordered.counts.total == 3)
    }

    @Test("an empty snapshot survives")
    func emptySnapshot() {
        let ordered = HerdUrgencyOrder.applying(recentlyCompleted: [], to: snapshot([]))
        #expect(ordered.sessions.isEmpty)
        #expect(ordered.counts.total == 0)
    }
}
