import Foundation
import HerdKit

/// The real working set the panel is designed against, as a snapshot fixture.
///
/// Every name here comes from the user's actual herd: four sessions, six workspaces, sixteen agents, mostly
/// `claude` with two `codex`, one stopped session that must stay visible, and one tab shared by two agents
/// so duplicate labels are exercised. Designing against placeholder content is how a panel ends up looking
/// good with `foo_bar` and falling apart on `loader_error_classification`.
///
/// Debug-only, reached solely from ``HerdDebugCapture`` when `HERDBAR_FIXTURE_DUMP` is set. It exists
/// because the all-idle case is the one the user sees most and the one the design is judged on, and it
/// cannot be produced on demand from a live herdr: you cannot ask sixteen real agents to go idle. Capturing
/// the live panel shows whatever the herd happens to be doing at that second.
enum HerdFixtureSnapshot {

    /// Shape of one agent in the fixture table, before statuses are applied.
    private struct Spec {
        let label: String
        let kind: String
        let status: AgentStatus
    }

    /// The workspace table for one session.
    private struct WorkspaceSpec {
        let id: String
        let number: Int
        let label: String
        let agents: [Spec]
    }

    /// The session table.
    private struct SessionSpec {
        let name: String
        let isDefault: Bool
        let running: Bool
        let workspaces: [WorkspaceSpec]
    }

    /// The mixed day: two agents waiting on the human, one working, two reporting done, one in an
    /// unrecognised state, ten idle. This is what the panel exists for, and it is the minority case.
    ///
    /// The two `done` agents are here for a reason beyond coverage: herdr only reports `done` when a real
    /// agent actually finishes, so it cannot be produced on demand any more than sixteen idle agents can.
    /// This fixture is the only way to see the green checkmark, the roll-up dot and the ordering before a
    /// live agent happens to finish while the panel is open.
    static var mixed: HerdSnapshot { build(table, allIdle: false) }

    /// The normal day: all sixteen idle. This is what the user actually sees, and it is where a flat
    /// sixteen-row list fails hardest, so every direction is judged on it as carefully as on ``mixed``.
    static var allIdle: HerdSnapshot { build(table, allIdle: true) }

    /// The fixture table itself.
    private static let table: [SessionSpec] = [
        SessionSpec(name: "default", isDefault: true, running: true, workspaces: [
            WorkspaceSpec(id: "w1", number: 1, label: "warehouse_cost", agents: [
                Spec(label: "loader_error_classification", kind: "claude", status: .blocked),
                Spec(label: "catalog_version_diff", kind: "claude", status: .done),
                Spec(label: "databricks_review", kind: "codex", status: .idle)
            ]),
            WorkspaceSpec(id: "w2", number: 2, label: "work_misc", agents: [
                Spec(label: "loader-memory-opt", kind: "claude", status: .working),
                Spec(label: "focal_review", kind: "claude", status: .done)
            ])
        ]),
        SessionSpec(name: "hail_mary", isDefault: false, running: true, workspaces: [
            WorkspaceSpec(id: "w1", number: 1, label: "sf-iceberg", agents: [
                Spec(label: "masked_merge_impl", kind: "claude", status: .blocked),
                // Two agents in one tab: legitimate, and the reason duplicate labels must render.
                Spec(label: "sf-iceberg-1", kind: "claude", status: .idle),
                Spec(label: "sf-iceberg-1", kind: "codex", status: .idle),
                Spec(label: "slow_load", kind: "claude", status: .idle),
                Spec(label: "saas_me", kind: "claude", status: .idle)
            ])
        ]),
        SessionSpec(name: "oncall_20-23_07", isDefault: false, running: true, workspaces: [
            WorkspaceSpec(id: "w1", number: 1, label: "services", agents: [
                Spec(label: "forget_me_not", kind: "claude", status: .idle),
                Spec(label: "slow_load", kind: "codex", status: .unknown)
            ]),
            WorkspaceSpec(id: "w2", number: 2, label: "shara_misc", agents: [
                Spec(label: "masked_merge_impl", kind: "claude", status: .idle),
                Spec(label: "catalog_version_diff", kind: "claude", status: .idle)
            ]),
            WorkspaceSpec(id: "w3", number: 3, label: "shara", agents: [
                Spec(label: "saas_me", kind: "codex", status: .idle),
                Spec(label: "focal_review", kind: "claude", status: .idle)
            ])
        ]),
        // Stopped, and still listed. A session that vanishes when its server stops is worse than one
        // that shows as stopped, because the user cannot tell that apart from a broken panel.
        SessionSpec(name: "shara_oncall_2-6_07", isDefault: false, running: false, workspaces: [])
    ]

    /// Materialises the table into a sorted, pre-aggregated snapshot.
    ///
    /// Sorting is applied here rather than in any view, exactly as `HerdSnapshotBuilder` does in the
    /// real app, so the prototypes render what they are given and never re-sort in a `body`.
    ///
    /// - Parameters:
    ///   - table: The session table to materialise.
    ///   - allIdle: When `true`, every agent's status is forced to `idle`, producing the normal-day case.
    /// - Returns: A snapshot with agents sorted inside each workspace and sessions in display order.
    private static func build(_ table: [SessionSpec], allIdle: Bool) -> HerdSnapshot {
        var sessions: [HerdSession] = []
        for session in table {
            var workspaces: [HerdWorkspace] = []
            for workspace in session.workspaces {
                var agents: [HerdAgent] = []
                for (index, spec) in workspace.agents.enumerated() {
                    let status = allIdle ? AgentStatus.idle : spec.status
                    agents.append(HerdAgent(
                        agent: spec.kind,
                        agentStatus: status,
                        cwd: "/Users/shara/code/\(spec.label)",
                        focused: index == 0 && workspace.number == 1,
                        paneId: "\(workspace.id):p\(index + 1)",
                        tabId: "\(workspace.id):t\(index + 1)",
                        workspaceId: workspace.id,
                        tabLabel: spec.label
                    ))
                }
                agents.sort(by: { lhs, rhs in
                    if lhs.agentStatus.sortRank != rhs.agentStatus.sortRank {
                        return lhs.agentStatus.sortRank < rhs.agentStatus.sortRank
                    }
                    return lhs.paneId < rhs.paneId
                })
                let rollUp = agents.reduce(AgentStatus.unknown) { $0.rollUp($1.agentStatus) }
                workspaces.append(HerdWorkspace(
                    workspaceId: workspace.id,
                    label: workspace.label,
                    number: workspace.number,
                    focused: workspace.number == 1,
                    agentStatus: rollUp,
                    paneCount: agents.count,
                    tabCount: agents.count,
                    activeTabId: agents.first?.tabId,
                    agents: agents
                ))
            }
            sessions.append(HerdSession(
                name: session.name,
                isDefault: session.isDefault,
                running: session.running,
                socketPath: "/Users/shara/.config/herdr/\(session.name)/herdr.sock",
                workspaces: workspaces
            ))
        }
        let agents = sessions.flatMap { $0.workspaces.flatMap(\.agents) }
        return HerdSnapshot(sessions: sessions, counts: StatusCounts(agents: agents))
    }
}
