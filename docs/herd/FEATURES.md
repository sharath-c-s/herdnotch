# boring-herd — herdr sessions in the MacBook notch

Feasibility verdict: **yes, feasible.** Everything below was verified on this machine (macOS 26.2, herdr 0.7.1, Swift 6.2.3) unless marked *unverified*.

## 1. Verified facts — data side (herdr)

| Question | Answer | How verified |
|---|---|---|
| Is herdr scriptable? | Yes. Newline-delimited JSON over a Unix domain socket, plus a CLI wrapper over the same API. | `herdr --help`, live socket calls |
| Where are the sockets? | Default session: `~/.config/herdr/herdr.sock`. Named sessions: `~/.config/herdr/sessions/<name>/herdr.sock` | `herdr status`, `herdr session list --json` |
| How do I enumerate sessions? | `herdr session list --json` returns `{name, default, running, session_dir, socket_path}` per session. This is CLI-level (directory scan + socket probe), not a socket method. | live call, 4 sessions found: `default`, `hail_mary`, `oncall_20-23_07`, `shara_oncall_2-6_07` (last one not running) |
| How do I enumerate agents in one session? | `agent.list` → array of `{agent, agent_status, cwd, foreground_cwd, focused, pane_id, tab_id, workspace_id, terminal_id, revision}` | live call, 6 agents in `hail_mary`, 5+ in `default` |
| What statuses exist? | `idle`, `working`, `blocked`, `unknown`. (`done` is additionally accepted by the blocking `wait` helpers.) | `herdr agent wait --status`, `herdr pane report-agent --state` |
| Which agent kinds does it detect? | `claude`, `codex`, `copilot`, `cursor`, `devin`, `droid`, `kimi`, `opencode`, `kilo`, `hermes`, `qodercli`, `pi`, `omp` | `herdr integration install <name>` list |
| Can I read another session without attaching? | Yes. Point `HERDR_SOCKET_PATH` at that session's socket, or use `--session <name>`. Resolution order: `--session` > `HERDR_SOCKET_PATH` > `HERDR_SESSION` > default socket. | live cross-session `agent.list` against the `default` socket while attached to `hail_mary` |
| Grouping metadata for the panel | `workspace.list` → `{workspace_id, label, number, focused, agent_status (rolled up), pane_count, tab_count, active_tab_id}`. `tab.list` → per-tab detail. | live calls, workspaces `w1 shara_misc`, `w2 shara` |
| Is there push, or must I poll? | Push exists: `events.subscribe`. Global subscriptions: `workspace.created/updated/renamed/closed/focused`, `worktree.created/opened/removed`, `tab.created/closed/focused/renamed`, `pane.created/closed/focused/moved/exited/agent_detected`. **Gotcha: `pane.agent_status_changed` is pane-scoped and requires a `pane_id`** — there is no global "any agent changed status" subscription. | probed every variant; got `subscription_started` for the global ones and `missing field pane_id` for `pane.agent_status_changed` |
| Cost of polling instead? | ~36 ms per `agent.list` round trip. Polling 4 sessions at 1 Hz is ~0.15 s of work per second spread across 4 short-lived connections, and near-zero if the panel keeps sockets open. | `time` over 5 sequential CLI calls |
| Auth? | None. Access control is filesystem permissions on the socket. Panel runs as the same user, so nothing to solve. | herdr socket-api docs |
| Can the panel act, not just observe? | Yes, same socket: `agent.focus`, `agent.send`, `workspace.focus`, `tab.focus`, `pane.send_keys`, `pane.read`, `agent.read`, `notification.show`. | full method list enumerated from the binary |
| Full method list | `ping`, `server.stop/live_handoff/reload_config/agent_manifests/reload_agent_manifests`, `notification.show`, `client.window_title.set/clear`, `workspace.create/list/get/focus/rename/close`, `worktree.list/create/open/remove`, `tab.create/list/get/focus/rename/close`, `agent.list/get/read/explain/send/rename/focus/start`, `pane.split/swap/move/zoom/layout/process_info/neighbor/edges/focus_direction/resize/list/current/get/rename/send_text/send_keys/send_input/read/report_agent/report_agent_session/report_metadata/clear_agent_authority/release_agent/close`, `layout.export/apply`, `events.subscribe`, `events.wait` | error response from an unknown method enumerates the enum |
| Stopped sessions | A stopped session has no live socket. Its structure is still readable statically from `~/.config/herdr/sessions/<name>/session.json` (workspaces, tabs, panes, cwds, custom names) — but no agent status, because status is runtime state. | read `hail_mary/session.json` |

## 2. Verified facts — UI side (the notch)

| Question | Answer | How verified |
|---|---|---|
| Does boringNotch have an extension/plugin API we can target? | **No.** "Extension system 🧩" is an unimplemented roadmap item in its README. There is no documented plugin API, URL scheme, IPC, or CLI. | fetched upstream README |
| Cost of forking boringNotch instead? | Its documented build path is `open boringNotch.xcodeproj` and it requires **Xcode 26 or later**. Only Command Line Tools are installed here, no Xcode. So this path starts with an Xcode install, then learning a full third-party SwiftUI app, then carrying a permanent merge burden. | `xcodebuild -version` → "requires Xcode, but active developer directory is a command line tools instance" |
| Can we build a standalone notch app with no Xcode? | Yes. `swiftc -parse-as-library` compiled a SwiftUI `App` + AppKit file against the CLT SDK and produced a working binary. An `.app` bundle is then a hand-written `Info.plist` (`LSUIElement = true`) plus an ad-hoc `codesign --sign -`. | compiled `probe.swift` successfully |
| Can we find the notch geometry? | Yes, public AppKit API, no private frameworks. On this display: `frame = 1512x982`, `safeAreaInsets.top = 32`, `auxiliaryTopLeftArea = (0, 950, 665, 32)`, `auxiliaryTopRightArea = (850, 950, 662, 32)` — so the notch occupies x 665→850, i.e. **185 pt wide, 32 pt tall**. Computing it from the two auxiliary areas keeps it correct on any machine, including notchless externals (where the auxiliary areas are nil and we fall back to a top-centre pill). | ran a Swift probe |
| Permissions needed? | None. A borderless `NSPanel` at `.statusBar` window level with `.canJoinAllSpaces` + `.stationary` needs no Accessibility, Screen Recording, or Automation grant. | *unverified in code, but standard AppKit; no private API involved* |
| Runtime footprint | Swift + AppKit, no browser engine, no external deps. Idle cost is one socket read loop per running session. | design consequence |

## 3. Decision: fork boringNotch, but menu bar ships first

**Decided: fork is the destination, a menu bar app is the first delivery.** See the revision note at the top of `PLAN.md` for the full reasoning and the measurements behind it. In short: Xcode cannot be installed at the moment (developer-portal `401`, and Command Line Tools lack `actool` and the Metal compiler as well as `xcodebuild`), and two independent apps cannot share one notch, because the collapsed strip is 189 pt and the expanded panel is 640 x 190 and both apps would contend for exactly those at the same window level. An `NSStatusItem` in the menu bar is the only placement that coexists with boringNotch without a fight, so that ships now; the fork's third tab ships when Xcode lands. `HerdKit` and the SwiftUI list view are shared verbatim between the two.

The rest of this section describes the fork, which remains the destination.

Consequences accepted, all verified against the upstream tree (19.6k lines Swift, 123 files):

- **Xcode 26 must be installed.** Only Command Line Tools are present. 80 GiB free, Xcode needs roughly half of that.
- **The app is sandboxed** (`boringNotch.entitlements` → `com.apple.security.app-sandbox = true`), so the app process cannot reach `~/.config/herdr/...` or `~/.local/bin/herdr` at all — those are outside its container. Spawning subprocesses *is* allowed (upstream already spawns `/usr/bin/perl` and `/usr/bin/zip`), but a child inherits the sandbox, so shelling out to the `herdr` CLI does not escape the problem. All herdr I/O has to happen in the **unsandboxed XPC helper** that already ships in the bundle (`BoringNotchXPCHelper`, its own entitlements set `app-sandbox = false`). This is the single biggest cost the fork adds over standalone, and it is the reason the plan has a dedicated data-layer phase.
- **Permanent rebase burden** against `TheBoredTeam/boring.notch` main.

Upstream facts that make the fork cheaper than feared:

- The tab system is trivially extensible: `NotchViews` enum (2 cases), a `tabs` array literal, and exactly one `switch coordinator.currentView` in `ContentView.swift:347`.
- Upstream's own "Extension system 🧩" is entirely commented-out dead code (`SettingsView.swift:1021-1154`), so there is no API to wait for and nothing to conflict with.
- `JSONLinesPipeHandler` already exists for reading newline-delimited JSON streams — which is exactly herdr's wire format.

## 4. Features

### v0 — the thing you actually asked for

1. **Session list.** Every herdr session from `session list --json`, running and stopped, each with its name and a running/stopped marker. Default session labelled as such.
2. **Agents under each session.** For each running session, its agents from `agent.list`, showing agent kind (`claude`, `codex`, …), status, and a short cwd (basename, full path on hover).
3. **Status made glanceable.** Colour + glyph per status: `working` (active), `blocked` (needs you — the one that matters), `idle`, `unknown`. Blocked sorts to the top.
4. **Roll-up in the collapsed notch.** With the panel closed, the notch itself shows counts — e.g. `2 blocked · 3 working · 6 idle` compressed to coloured dots with numbers. This is the whole point: information without opening anything.
5. **Grouping by workspace.** Agents nested under their workspace label (`shara_misc`, `shara`) rather than a flat list, using `workspace.list` for labels and the rolled-up per-workspace status.
6. **Live updates.** Panel reflects reality within ~1 s of a status change, without user action.
7. **Hover to open, click-out to close.** Standard notch interaction: expand on hover over the notch region, collapse on mouse-out or Escape.
8. **Multi-display and notchless safety.** Correct placement on the built-in notched display; graceful top-centre pill on external monitors and on Macs with no notch.
9. **Survives herdr restarts.** Sessions starting, stopping, or the server being restarted must not require restarting the panel — reconnect with backoff, show stopped sessions as stopped rather than vanishing.

### v1 — earns its place quickly

10. **Click an agent to jump to it.** `workspace.focus` + `tab.focus` + `agent.focus` on the owning session, then raise the terminal app. This turns the panel from a dashboard into a switcher.
11. **Blocked-agent notification.** When an agent transitions into `blocked`, fire a native notification. Optional per-status toggle, off by default for `idle`.
12. **Last-line preview.** `agent.read --source visible --lines 1` (or a few) per agent, so you can see *what* it is blocked on without switching to it. Fetch lazily on hover, not for every agent every tick — this is the one call expensive enough to matter.
13. **Menu bar fallback item.** Same data as a menu bar dropdown, for external-display-only setups and for people who dislike hover targets.
14. **Launch at login.** `SMAppService.mainApp.register()`.

### Parked — do not build yet

- **Send input from the panel.** `agent.send` / `pane.send_keys` exist, so a reply box is possible. Skipped: it invites typing into the wrong agent, and the fix (confirm-target UI) costs more than the feature is worth. Add when you find yourself answering the same one-word prompt repeatedly.
- **Herdr plugin instead of a notch app.** herdr has its own plugin system (`herdr plugin install <owner>/<repo>`, `herdr plugin pane open`, ~150+ community plugins auto-discovered from GitHub) and could host this as an in-terminal panel. That is a different product — visible only when herdr is on screen, which is exactly when you don't need it. Worth knowing it exists.
- **Remote sessions.** `herdr --remote <ssh-target>` exists. Reading a remote server's socket means SSH-forwarding it. Skipped until there is a remote session to watch.
- **History and charts.** Time-in-status, agents-per-day. Skipped: `session-history.json` exists on disk if this ever becomes interesting.
- **Per-pane `pane.agent_status_changed` subscriptions.** The precise, push-based design. Skipped for v0 in favour of polling `agent.list` at 1 Hz, which is ~36 ms per session per tick and needs no subscription bookkeeping. Switch if the poll ever shows up in Activity Monitor.
