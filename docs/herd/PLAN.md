# boring-herd — implementation plan

Companion to `FEATURES.md`. Feature numbers below refer to that document's section 4.

Everything here is anchored to the real upstream tree at `main` (19,609 lines Swift / 123 files, inspected). Line numbers are from that snapshot and will drift; the symbol names will not.

## Revision, 2026-07-31: two tracks, menu bar first

The fork remains the destination, but it is no longer the first delivery. Two things forced the split, both verified rather than assumed:

**Xcode cannot be installed right now.** Xcodes.app 4.0.5b40 fails Apple developer-portal auth with `401`. Command Line Tools alone cannot build this project, and not only because `xcodebuild` is a stub: `actool` is also a stub (so `Assets.xcassets` cannot compile) and the Metal compiler is absent entirely (so `boringNotch/metal/visualizer.metal` cannot compile). Rewriting a 19.6k-line `.xcodeproj` app as a SwiftPM package would dodge `xcodebuild` but would permanently diverge from upstream, destroying the only reason to fork. So the fork is blocked on a one-time Xcode install, not on any code decision.

**Two apps cannot share one notch.** The requirement is to see boringNotch and the herd panel at the same time. Measured on this display, the collapsed notch strip is `1512 - 665 - 662 + 4 = 189` pt and the expanded panel is `openNotchSize = 640 x 190`. Two independent apps would contend for exactly that strip and exactly that rectangle, both at `.statusBar` window level, both hover-triggering on the same mouse region. A standalone app that expands from the notch therefore cannot coexist with boringNotch. Only two placements coexist cleanly: a third tab inside boringNotch itself (the fork), or an `NSStatusItem` in the menu bar, where the OS owns placement and collision is impossible by construction.

Hence:

- **Track A, now, no Xcode: `BoringHerdBar`** — a standalone `LSUIElement` menu bar app. `NSStatusItem` shows the roll-up dots; clicking opens a panel with the session and agent list. Coexists with boringNotch permanently. This promotes feature 13 from "v1 fallback" to the primary v0 surface. Feature 4's roll-up moves from the collapsed notch into the status item, where it is arguably better anyway: always visible, no priority fight with music.
- **Track B, later, when Xcode lands: the fork.** Phases 2 through 5 exactly as written below, unchanged. This is what finally delivers "both in one notch".

What makes the split nearly free: `HerdKit` is shared verbatim, and the SwiftUI list view is written host-agnostic (it takes a `HerdSnapshot` plus callbacks, and imports nothing from either host, no `Defaults`, no upstream types), so it lifts into the fork as-is. The genuine throwaway is roughly 80 lines of `NSStatusItem` and app-bundle glue, and even that survives as feature 13 for external displays, where there is no notch to put anything in.

One simplification Track A gets for free: a standalone app is **not sandboxed**, so it reads the herdr sockets directly. The entire XPC helper layer exists only for Track B. Track A does not need it.

Repository layout, one repo, three coexisting parts:

```
boring-herd/            fork of boring.notch, branch herd-panel
  HerdKit/              shared SwiftPM package, pure Foundation, no UI      Track A + B
  BoringHerdBar/        standalone menu bar app, SwiftPM executable         Track A
  boringNotch/          the fork itself, .herd tab                          Track B
  BoringNotchXPCHelper/ herdr I/O for the sandboxed fork                    Track B
  docs/herd/            these documents
```

Only `boringNotch/` and `BoringNotchXPCHelper/` touch upstream files, so the added directories cost nothing at rebase time.

Track B's phases are unchanged and are documented in full below. Track A's phases are appended at the end as Phase A1 to A3.

## Architecture in one paragraph

The app process is sandboxed and therefore cannot see `~/.config/herdr/**` at all, so **every byte of herdr I/O happens inside the existing unsandboxed `BoringNotchXPCHelper` XPC service**. The helper speaks herdr's newline-delimited-JSON protocol directly over the per-session Unix domain sockets, assembles one snapshot object, and hands it back across XPC as `Data`. On the app side a single `HerdManager` observable object polls the helper and publishes a session → workspace → agent tree; a new `.herd` tab renders it. Hover-to-open, click-out-to-close, multi-display placement, and notch geometry all come free from the host app — that is what the fork buys.

Polling, not subscriptions. herdr's `pane.agent_status_changed` event is **pane-scoped** (requires a `pane_id`), so a push design means subscribing per pane and re-subscribing on every `pane.created` / `pane.closed`. A measured `agent.list` round trip is ~36 ms. Poll at 1 Hz and skip the bookkeeping.

---

## Phase 0 — Prerequisites and a green baseline

Do not write a line of feature code until this phase passes.

1. **Install Xcode 26.** Currently only Command Line Tools are present (`xcode-select -p` → `/Library/Developer/CommandLineTools`). Then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
   *Verify:* `xcodebuild -version` prints `Xcode 26.x`. Disk: 80 GiB free, Xcode wants roughly half.
2. **Fork and clone.** Fork `TheBoredTeam/boring.notch` on GitHub, clone into `/Users/dev/playground/boring-herd` (currently empty), add `upstream` remote, create branch `herd-panel`.
   *Verify:* `git remote -v` lists both `origin` (your fork) and `upstream`.
3. **Build and run the unmodified app.**
   *Verify:* `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch build` succeeds, the app launches, the notch expands, Home and Shelf tabs both work.

**Gate A:** baseline green. If Xcode install fails or upstream `main` is broken, stop here and reconsider — there is nothing to build on.

---

## Phase 1 — HerdKit, helper side (the unsandboxed half)

New files under `BoringNotchXPCHelper/Herd/`:

- **`HerdrSocket.swift`** — `AF_UNIX` connect, write one JSON line, read until `\n`, decode. Configurable timeout (default 2 s), explicit close. One request per connection for v0; keep-alive is a later optimisation, not a v0 requirement.
- **`HerdrDiscovery.swift`** — enumerate sessions without depending on the `herdr` binary's location: the default session is `~/.config/herdr/herdr.sock`, named sessions are `~/.config/herdr/sessions/<name>/herdr.sock`. `running` is decided by whether `connect()` succeeds, which is exactly how the CLI decides it. Re-implementing this beats shelling out — no PATH assumptions, no process spawn.
- **`HerdModels.swift`** — `Codable` mirrors of the verified wire shapes. `HerdAgent` (`agent`, `agentStatus`, `cwd`, `foregroundCwd`, `focused`, `paneId`, `tabId`, `workspaceId`, `terminalId`), `HerdWorkspace` (`workspaceId`, `label`, `number`, `focused`, `agentStatus`, `paneCount`, `tabCount`, `activeTabId`), `HerdSession`, and `AgentStatus { idle, working, blocked, unknown }` where **an unrecognised string decodes to `.unknown` rather than throwing** — herdr may add states and the panel must not go blank when it does.
- **`HerdSnapshot.swift`** — for each discovered session: `workspace.list` then `agent.list`, assembled into the tree. One session failing must not fail the snapshot; record a per-session error instead.

Extend the XPC protocol. Note upstream keeps **two copies** of `BoringNotchXPCHelperProtocol.swift` (one in `boringNotch/XPCHelperClient/`, one in `BoringNotchXPCHelper/`); they must stay byte-identical.

```swift
func herdSnapshot(with reply: @escaping (Data?, String?) -> Void)
func herdFocusAgent(session: String, workspaceId: String, tabId: String, paneId: String,
                    with reply: @escaping (Bool) -> Void)
func herdReadAgent(session: String, paneId: String, lines: Int,
                   with reply: @escaping (String?) -> Void)
```

Passing JSON-encoded `Data` across XPC instead of custom `NSSecureCoding` classes keeps the interface trivial and versionable. `herdFocusAgent` and `herdReadAgent` are stubs in this phase — wired up in Phase 6, declared now so the protocol is not revised twice.

*Verify:* Phase 1b tests, plus one manual cross-check of the snapshot against `herdr agent list` for all four sessions.

## Phase 1b — Tests

Upstream has **no test target at all**, so add `HerdKitTests` (unit, XCTest). Fixtures are real payloads captured from this machine, not invented ones.

| Test | Asserts |
|---|---|
| `decodesRealAgentList` | captured `hail_mary` payload → 6 agents, correct kinds, correct statuses |
| `unknownStatusDecodesToUnknown` | `"agent_status": "sleepwalking"` → `.unknown`, no throw |
| `discoversRunningAndStoppedSessions` | fixture directory tree → `default`/`hail_mary`/`oncall_20-23_07` running, `shara_oncall_2-6_07` stopped |
| `rollUpPrefersBlocked` | mixed statuses → `blocked` beats `working` beats `idle` beats `unknown` |
| `ndjsonFramingHandlesSplitAndCoalescedReads` | two replies arriving in one `recv` → two messages; a half line → buffered until completed |
| `oneDeadSessionDoesNotFailSnapshot` | one socket refusing connections → other sessions still returned, error recorded |

**Gate B:** tests green and the snapshot matches the CLI. The data layer is the risky half — prove it before any UI exists.

---

## Phase 2 — HerdManager, app side

New: `boringNotch/managers/HerdManager.swift` — `@MainActor final class HerdManager: ObservableObject`, `static let shared`, matching the shape of the existing `MusicManager` / `BatteryActivityManager`.

- `@Published var sessions: [HerdSession]`, `@Published var counts: StatusCounts`, `@Published var lastError: String?`
- Polls `XPCHelperClient.herdSnapshot()` on a `Task` loop at `Defaults[.herdPollInterval]` (default 1.0 s).
- **Backs off to 5 s when nothing is showing** — i.e. notch closed and the collapsed indicator disabled. Idle cost matters more than latency you cannot see.
- Reconnects with exponential backoff on XPC interruption; surfaces "helper unavailable" and "herdr not running" as distinct states so the UI can say something useful.

*Verify:* log a snapshot on each tick and diff against `herdr agent list` by hand; confirm the 5 s backoff engages with the notch closed.

---

## Phase 3 — The Herd tab (features 1, 2, 3, 5, 7, 8, 9)

Four one-to-four-line edits to upstream files:

| File | Edit |
|---|---|
| `boringNotch/enums/generic.swift` | `NotchViews` → add `case herd` |
| `boringNotch/components/Tabs/TabSelectionView.swift` | append `TabModel(label: "Herd", icon: "point.3.connected.trianglepath.dotted", view: .herd)` to the `tabs` array |
| `boringNotch/ContentView.swift` (~line 347) | the one `switch coordinator.currentView` → add `case .herd: HerdView()` |
| `boringNotch/BoringViewCoordinator.swift` | nothing yet; Phase 4 touches it |

New: `boringNotch/components/Notch/HerdView.swift` and `HerdRowView.swift`.

- Session header: name, `default` badge, running/stopped marker.
- Workspace subheader using the `label` from `workspace.list` (`shara_misc`, `shara`) with its rolled-up status.
- Agent row: status dot, agent kind, `cwd` basename (full path on hover).
- **Blocked agents sort to the top** — the whole point of the panel.
- Empty state via upstream's existing `components/EmptyState.swift`.
- Distinct, non-alarming states for "no herdr sessions found" vs "XPC helper unreachable".

Features 7 (hover open / click-out close) and 8 (multi-display, notchless fallback) require **no work** — inherited from the host app.

*Verify:* open the Herd tab and reconcile against `herdr agent list` across all four sessions; `herdr session stop <name>` and confirm the session renders as stopped rather than disappearing; kill and restart the herdr server and confirm the panel recovers without an app restart (feature 9).

**Gate C:** v0 is usable. Actually use it for a few days before starting Phase 4. Real use will reorder the rest of this list, and that reordering is worth more than finishing the list as written.

---

## Phase 4 — Collapsed-notch roll-up (feature 4)

The fiddly one, and the only place the fork genuinely fights the host. The collapsed slot is an `else if` chain in `ContentView.swift:287-301` already contested by battery notifications, `InlineHUD`, `MusicLiveActivity`, and the face animation.

- `BoringViewCoordinator.swift`: add `case herd` to `SneakContentType`.
- New `HerdLiveActivity()` view mirroring `MusicLiveActivity`'s shape and sizing.
- **Insert below music in the priority chain** — show only when the player is idle. Never fight the thing the user is deliberately looking at.
- Content: coloured dots with counts (`● 2  ◐ 3  ○ 6`); render the blocked dot only when the count is non-zero, so the common case stays quiet.
- Gate on `Defaults[.herdShowInClosedNotch]`.

*Verify:* with music paused the counts appear; with music playing music wins; toggling the default hides it entirely; the closed notch does not change width when counts go from 1 to 2 digits.

---

## Phase 5 — Settings and blocked notifications (features 11, 14)

- `boringNotch/models/Constants.swift` — new `Defaults.Keys`: `herdEnabled` (true), `herdShowInClosedNotch` (true), `herdPollInterval` (1.0), `herdNotifyOnBlocked` (true), `herdSessionFilter` (`[String]`, empty means all).
- `enums/generic.swift` `SettingsEnum` → `case herd`; `components/Settings/SettingsView.swift` → a Herd pane plus its `NavigationLink`. Follow the live panes; **ignore the commented-out Extensions block at lines 1021-1154**, it is abandoned code and not a template.
- Blocked notification: fire on an `idle|working|unknown → blocked` transition only. Two guards that matter: debounce per pane, and **suppress the entire first snapshot after launch** so restarting the app does not replay every already-blocked agent as new.
- Launch at login (feature 14) is already in the host app via `LaunchAtLogin-Modern` — free.

*Verify:* drive one agent into `blocked`, confirm exactly one notification; restart the app with a blocked agent present, confirm zero notifications.

---

## Phase 6 — v1 (features 10, 12, 13), only after v0 has been lived with

- **Feature 10, click to jump.** Wire the `herdFocusAgent` stub: `workspace.focus` → `tab.focus` → `agent.focus`, then activate the terminal app. The unknown is *which* terminal hosts herdr; make it `Defaults[.herdTerminalBundleId]` with auto-detection as the default rather than guessing.
- **Feature 12, last-line preview.** `agent.read` with `source: visible`, 3 lines, **on hover only**, 500 ms debounce, 2 s cache. This is the one call expensive enough to matter; it must never enter the tick loop.
- **Feature 13, menu bar fallback.** Extend upstream's `menu/StatusBarMenu.swift`.

---

## Fork hygiene

Only **8 upstream files** are touched, none by more than a few lines: `enums/generic.swift`, `components/Tabs/TabSelectionView.swift`, `ContentView.swift`, `BoringViewCoordinator.swift`, `models/Constants.swift`, `components/Settings/SettingsView.swift`, and both copies of `BoringNotchXPCHelperProtocol.swift`. Everything else is new files under `Herd/` directories.

- Keep the upstream-file edits in **one commit, separate from the feature commits**, so a rebase conflicts in exactly one reviewable place.
- `boringNotch.xcodeproj/project.pbxproj` will conflict on essentially every upstream rebase. This is unavoidable with an `.xcodeproj`; resolve by taking upstream's version and re-adding the new files in Xcode rather than hand-merging the pbxproj.
- Rebase on `upstream/main` before starting each phase, not after finishing all of them.

## Effort

| Phase | Estimate |
|---|---|
| 0 — prereqs, baseline | ~1 h of work plus the Xcode download |
| 1 + 1b — data layer and tests | ~4-5 h |
| 2 — HerdManager | ~2 h |
| 3 — the tab (v0 complete) | ~3 h |
| 4 — collapsed roll-up | ~2 h |
| 5 — settings, notifications | ~2 h |
| 6 — v1 | ~3 h |

v0 (Phases 0-3) is roughly **10 hours of work** plus the Xcode install.

---

# Track A — `BoringHerdBar`, the menu bar app (no Xcode)

Delivers features 1, 2, 3, 5, 6, 9, 13 immediately, and 4 in its status-item form. Everything here builds and runs with Command Line Tools only.

## Phase A1 — buildable app bundle skeleton

`BoringHerdBar/` as a SwiftPM executable depending on the local `HerdKit` package. No asset catalog and no Metal, deliberately: `actool` and the Metal compiler are both unavailable, so every icon is an SF Symbol drawn in code and every colour is defined in Swift. This is a constraint that happens to produce less code, so it is not worth fighting.

`BoringHerdBar/build.sh` assembles a real `.app` by hand, because SwiftPM only produces a bare executable:

1. `swift build -c release`
2. create `BoringHerdBar.app/Contents/{MacOS,Resources}`
3. write `Info.plist` with `LSUIElement = true` (no Dock icon, no menu bar title of its own), `CFBundleIdentifier`, `LSMinimumSystemVersion = 14.0`
4. copy the binary in
5. `codesign --force --sign - --options runtime` ad-hoc

*Verify:* `./build.sh && open BoringHerdBar.app` puts an item in the menu bar and leaves no Dock icon.

## Phase A2 — status item and the panel

- `HerdStatusItem.swift` — owns the `NSStatusItem`. Its button title is the roll-up (feature 4 relocated): coloured dots with counts, blocked dot rendered only when non-zero so the common case stays quiet, `.monospacedDigit()` so the item does not jitter between 1 and 2 digit counts. Uses an `NSHostingView` for the title so the same SwiftUI styling serves both surfaces.
- `HerdPanel.swift` — an `NSPopover` anchored to the status item, hosting the list. `NSPopover` rather than a hand-placed `NSPanel`: it gets click-outside dismissal, correct screen-edge behaviour, and keyboard escape for free. That is features 7 and 8 solved by the OS instead of by us.
- `HerdListView.swift` — the shared SwiftUI list. **Host-agnostic by discipline:** it takes a `HerdSnapshot` and a `(HerdAgent) -> Void` callback, and imports only `SwiftUI` and `HerdKit`. No `Defaults`, no upstream types, no singletons. This is the file that lifts into the fork verbatim in Track B, so the discipline is the whole point.
- `HerdBarModel.swift` — the standalone equivalent of Track B's `HerdManager`, but calling `HerdKit` **directly** rather than through XPC, since a standalone app is not sandboxed. Same 1 Hz poll, same back-off to 5 s while the popover is closed, same distinct `.ok` / `.noSessions` / `.error` states.

*Verify:* run it, open the popover, reconcile every row against `herdr agent list` across all four sessions. `herdr session stop <name>` and confirm the session renders as stopped rather than vanishing (feature 9). Kill and restart the herdr server and confirm recovery with no app restart.

## Phase A3 — settings, notifications, click-to-focus

- Preferences via `UserDefaults` directly, not the `Defaults` package: five keys is not worth a dependency. Same key names as Track B (`herdEnabled`, `herdPollInterval`, `herdNotifyOnBlocked`, `herdSessionFilter`) so behaviour matches across the two surfaces.
- A small `NSMenu` on right-click for quit, preferences, and poll interval. No settings window: a menu covers five booleans.
- Blocked notification (feature 11) via `UNUserNotificationCenter`, with the two guards that matter: debounce per `paneId`, and suppress the entire first snapshot after launch so a restart does not replay every already-blocked agent as new.
- Click-to-focus (feature 10) comes nearly free here: `HerdKit` already exposes `workspace.focus`, `tab.focus`, `agent.focus`, and a standalone app can call them directly. The one unknown remains which terminal app hosts herdr, so it stays a preference with auto-detect as the default.

*Verify:* drive one agent to `blocked`, confirm exactly one notification; restart the app with a blocked agent present, confirm zero; click a row and confirm the correct pane focuses.

## Track A effort

| Phase | Estimate |
|---|---|
| A1 — bundle skeleton, build.sh | ~1.5 h |
| A2 — status item, popover, list | ~3 h |
| A3 — prefs, notifications, focus | ~2 h |

Roughly **6.5 hours**, and unlike Track B every hour of it is verifiable today.

## Status and open follow-ups, 2026-07-31

**Track A is built, running, and reconciles against the live CLI** (16 agents across 4 sessions). `HerdKit` is 12/12 green. Track B is written and reviewed but has never been compiled, because Xcode is still not installed.

An independent Codex review covered both tracks. It cleared five of the six flagged guesses (multi-argument `@objc` XPC methods, `Task` reply-block captures, SF Symbols at the macOS 14 floor, collapsed-notch priority and fixed width, and the actor plus serial-queue fix in `HerdXPCService`). Every confirmed defect it found has been fixed and, where testable, proven with a negative control: `SIGPIPE` killed the process at exit 141 before `SO_NOSIGPIPE` and returns a clean `EPIPE` after, and the end-to-end deadline measured 1.004 s with the fix against 1.508 s with it reverted.

One review item was deliberately declined rather than implemented: response-id correlation in `HerdrClient`. Each call opens a fresh socket, sends one request, and closes, with no pipelining, no reuse, and no `events.subscribe`, so no mismatched id can reach that code. Error envelopes return `id: ""` and are uncorrelatable anyway. Validation would guard only the success case that already cannot fail.

### Follow-ups, none blocking

- ~~**Model `done` as a first-class `AgentStatus`.**~~ **Done, 2026-08-03.** `AgentStatus.done` ranks after `blocked` in both the display order and the roll-up, `HerdUrgency` gains a matching case above the inferred `recentlyCompleted`, `StatusCounts` gains a `done` field with an explicit decoder so payloads written before the field existed still decode, and the transient popup's completion test now accepts any transition into `done` as well as `working -> idle`. It draws as a green checkmark, sharing the recency mark's shape and differing only in colour. Two notes for anyone re-checking it: the wire spelling was re-confirmed from the shipped binary's serde variant list, `idle working blocked done unknown`, because **`done` could not be reproduced live on the day it was implemented** (`agent.list` returned only `working` and `idle` across four sessions), so it is fixture-verified and the first real sighting is still the true acceptance test. If herdr ever spells it differently in a payload, the `unknown` fallback means nothing fails loudly, it simply reverts to the old behaviour.
- ~~**Dynamic Type: sizes are fixed point values with no `@ScaledMetric`.**~~ **Closed as superseded, 2026-08-03**, not built. Three reasons, and the first is structural rather than a preference. The ledger is a measured table: its column widths come from CoreText at a specific point size and that measurement happens *before* layout, so the size must be a number this code holds, not a multiplier resolved inside a view body. The user asked to tune this by eye, which a system-wide setting cannot do per app. And macOS ships no Dynamic Type control comparable to iOS's, so the multiplier would resolve to 1.0 and the work would deliver nothing. The five-step `ledgerTextSize` control added in the settings window is what this follow-up was actually asking for, and it moves the whole scale together, row height and gutter and sigil diameters included. See `HerdLedgerScale` in `HerdLedgerColumns.swift`, which states the same argument at the point of the decision.
- **herdr's own palette still disagrees with the panel's, and cannot be made to agree from here.** The panel draws red for blocked, amber for working, green for done, blue for idle. herdr draws a completed agent in blue, which is what prompted the recolour in the first place. herdr is a closed Mach-O binary, and its `[theme.custom]` config block exposes token *values* only (`panel_bg`, `surface0`, `surface1`, `surface_dim`, `overlay0`, `overlay1`, `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, `peach`), never the status-to-token mapping. So making herdr agree would mean globally redefining `blue` and `green`, repainting every other use of those tokens in its chrome. Deliberately not done. If uniformity matters, it is a request to herdr upstream, not a change available here.
- **Notifications cannot be authorized for an ad-hoc signed bundle.** `UNUserNotificationCenter` returns `UNErrorDomain Code=1, "Notifications are not allowed for this application"`, so feature 11's banner path is exercised but can never appear in `BoringHerdBar`. The transient menu bar popup is currently the only working alert surface, which is why it matters more than originally scoped. A Developer ID signature fixes this; the fork will not have the problem because boringNotch is properly signed.
- **SwiftPM caches the path-dependency file list.** Adding a file to `HerdKit` does not invalidate `BoringHerdBar/.build/release.yaml`, so the app silently compiles against the old file set until the stale build plan is deleted. Touching `Package.swift` is not enough. It fails as a compile error rather than silently producing wrong behaviour, but it costs time. Delete the build plan after adding any `HerdKit` source file.
- **`HerdAgent.id` is `paneId`, which is session-scoped.** Fine today because the views nest agents under their session, but any future flat list across sessions would hit duplicate SwiftUI identities. The notification and popup paths already key on `(sessionName, paneId)`; a view that flattens must do the same.

## Second pass, 2026-07-31

Four things changed in `BoringHerdBar` after living with it, plus one question answered.

- **Keyboard focus.** The list used `@FocusState` per row, and SwiftUI assigned focus to the first row as soon as the popover became key, so the first Down press appeared to skip row one. Selection is now plain `@State` owned by the list, which nothing outside can pre-assign, with the scroll view as the single focusable element and a `ScrollViewReader` doing the scroll-to-selection that focus used to do for free. Verified by replaying synthetic key events into the popover and capturing: one Down selects row one, two selects row two, three crosses a workspace header without stopping on it.
- **The rail is gone**, token and geometry both, and `DESIGN.md`'s signature-element section is rewritten around what replaces it: a derived three-level indentation ladder, and a status dot moved to sit immediately left of its label. The dot had to move; deleting the rail without closing that gap left the dot stranded in the margin, because the rail was what had been explaining the distance.
- **Pane search**, on a Carbon global hotkey defaulting to `⌃⌥⌘H`. Fuzzy subsequence ranking lives in `HerdKit/HerdPaneSearch.swift` with 14 tests, so the ranking is testable without a running app; the view is `HerdSearchView.swift` and keeps the same SwiftUI-plus-HerdKit-only discipline as `HerdListView`.
- **Session and workspace headers are click targets**, both routed through `workspace.focus`. Verified against the live server by clicking and diffing `workspace.list`.

**Attachment is not detectable, and this is settled rather than assumed.** The candidate signal was `herdr-client.sock`, which sits beside every session's API socket. It is created by the *server*: the client log records the client *connecting to* that path, `src/server/headless.rs` owns both `api_socket` and `client_socket`, and the negative control is conclusive — a server started with `herdr --session herdbar_probe server`, which no client has ever attached to, accepts connections on it immediately. The API is no better: none of the 76 methods reports attached clients, and none of the 20 subscribable events announces attach or detach. So a detached session cannot be marked, and the fallback is to make the failure legible instead: focusing a pane now names the session it landed in, and the row tooltip carries `herdr session attach <name>`.

## When Xcode arrives

`HerdListView.swift` moves into `boringNotch/components/Notch/` and is wrapped by the fork's `HerdView`, which supplies the snapshot from `HerdManager` and the upstream styling context. `HerdKit` is added to the `BoringNotchXPCHelper` target. `BoringHerdBar` stays in the tree as the external-display surface (feature 13) rather than being deleted.

## Third pass, 2026-07-31: dynamic columns, and why the cross-session raise did nothing

Two user-reported defects, one of which had a cause nobody had guessed at.

### Clicking a row in a session the terminal was not showing did nothing

The AppleScript was never the problem, and neither was the marker. Both were checked directly: the stamped title `herdr: <session>` survives a `workspace.focus` / `tab.focus` / `agent.focus` sequence and persists indefinitely, and running the locator's exact script body by hand switched iTerm2 to the right tab every time. The cause was the **code signature**, in two layers, and both layers fail without producing anything a user or a log could see.

**Layer one: the hardened runtime with no Apple-events entitlement.** `build.sh` signs with `codesign --options runtime`, and under the hardened runtime a process may not send an Apple event at all unless it carries `com.apple.security.automation.apple-events`. That check happens inside the *sending* process before TCC is consulted, so `NSAppleScript` returned `-1743` on its very first execution, no consent prompt was ever shown, the app never appeared in System Settings under Privacy and Security > Automation, and `tccd` logged nothing whatsoever. `NSAppleEventsUsageDescription` in the Info.plist did not help, because that string is only the text of a prompt that was never going to happen. The locator then reported `scriptingUnavailable`, `HerdFocusService` fell back to `NSRunningApplication.activate()`, and activating iTerm2 brought forward the tab that was already current, which is precisely what "does nothing" looks like.

**Layer two: the consent prompt being killed by the script's own timeout.** With the entitlement added, the first send does reach TCC and does raise the Automation dialog. But the script is wrapped in `with timeout of 2 seconds`, and no human answers a dialog in two seconds. The wrapper fired, AppleScript returned `-1712`, and the abandoned prompt was recorded by TCC as auth_value 0, a **denial**, after which every later attempt failed with `-1743` and no prompt, permanently. The `-1712` seen in an earlier pass and written off as a test-harness artefact was real; it was a self-inflicted denial in progress.

The fix is both halves: `build.sh` now signs the `com.apple.security.automation.apple-events` entitlement in and verifies it landed, and `HerdTerminalWindowLocator` asks for consent through `AEDeterminePermissionToAutomateTarget` **before** any timed script runs, so the user gets as long as they like to answer and a refusal comes back as a message naming the System Settings pane rather than as silence. The ask happens after the attachment probe, so clicking a row in a genuinely detached session still returns `notAttached` without ever prompting.

**Why this was invisible in testing.** A build launched straight from a shell inherits the calling terminal's own Automation grant through TCC's responsible-process attribution, so the raise worked when the binary was run by hand and failed only when LaunchServices launched the bundle as its own responsible process, which is the only way a user ever launches it. Any future verification of this feature has to go through `open BoringHerdBar.app`, never through `./BoringHerdBar.app/Contents/MacOS/BoringHerdBar`.

Verified after the fix, all three through a real click in the popover with the shipped build: iTerm2 showing `default` and a `hail_mary` row clicked switches to `hail_mary`; the reverse switches back; and with Finder frontmost the same click brings iTerm2 forward *and* lands on the right tab. `oncall_20-23_07` still reports `notAttached` and attempts no raise.

**The window match is also exact now.** It used to ask whether a title *contained* `herdr: <session>`, so raising `default` would have matched a window belonging to `default2` while reporting success. The rule lives in `HerdrClient.windowTitle(_:isFor:)` with seven tests: the title must be the marker outright or the marker followed by a separator a terminal is known to append after, which is `" ("` for iTerm2's job suffix and a spaced em dash for Terminal.app's shell and size suffix.

### Column widths are measured rather than declared

See **Type** in `DESIGN.md` for the reasoning and the numbers. The mechanical notes: measurement is `HerdLedgerColumns` in `HerdPanelUI`, it imports CoreText and still not AppKit, and there is now a `HerdPanelUITests` target in the `BoringHerdBar` package holding thirteen tests for it, run with the same framework search path flags `HerdKit` needs.

One trap for anyone editing that file: `NSAttributedString.Key.font` is declared by AppKit and UIKit, not by Foundation, so writing `[.font: …]` there compiles only for as long as some other file in the module imports AppKit transitively through SwiftUI. It did compile, which is the problem, since the portability rule the target exists to enforce would have been broken by an expression that never names AppKit. The measurement therefore builds its attributed string with `CFAttributedStringCreate` and `kCTFontAttributeName`.

Idle cost is unchanged in practice: 0.23 % of one core measured from `ps` over 100 seconds with the panel open, against the 0.3 % baseline. Measuring costs about 16 microseconds per string, so a full remeasure of a sixteen-agent ledger is about 1 ms and happens at the 1 Hz poll.

## Fourth pass, 2026-07-31: a configurable shortcut, a settings window, and forwarded remote sessions

### The global shortcut is configurable, and defaults to a double tap of `fn`

The shortcut was a hardcoded Carbon registration on `⌃⌥⌘H` with no interface and two documented `defaults write` keys. Three things changed.

**It is now a value in its own target.** `BoringHerdBar/Sources/HerdShortcut/` holds `HerdShortcut` (key code, modifier mask, display name) and `HerdShortcutStore` (the `UserDefaults` round trip). A target rather than a nested type, and the reason is testability: SwiftPM cannot import an executable module whose entry point is top-level code in `main.swift`, so nothing inside `BoringHerdBar` can be unit-tested at all. It is not in `HerdKit` because it imports `Carbon.HIToolbox` and `HerdKit` is pure Foundation shared with the parked fork's XPC helper, and not in `HerdPanelUI` because that target is SwiftUI-and-HerdKit-only so it lifts into the fork verbatim.

**The old encoding could not store the new default.** It treated `code > 0 && modifiers > 0` as "the user overrode it", which silently made `kVK_ANSI_A` unstorable (it is literally `0`) and every modifier-free binding unstorable too. Unset is now `-1`. That mattered immediately, because the shipped default is a bare function key with a zero modifier mask.

**The default is `F19`, reached by pressing `fn` twice.** Carbon cannot register `fn`: `RegisterEventHotKey` takes a virtual key code plus a modifier mask and `fn` is neither, it is absent from Carbon's modifier vocabulary, and the raw key arrives as a `flagsChanged` event the hot-key mechanism never sees. The only in-process alternative is a `CGEventTap` on `flagsChanged`, which needs Input Monitoring, a TCC permission this app otherwise does not want and cannot get without another consent prompt. So a Karabiner-Elements complex modification maps a double tap of `fn` to `F19` and the app registers `F19` like any other hot key. `F19` because no Apple keyboard has it, so nothing on this machine competes for it and a modifier-free binding is safe.

The rule is `karabiner/herd-fn-double-tap.json` and `karabiner/install-fn-rule.sh` appends it. It backs the config up, appends rather than replaces, and matches on `description` so a second run replaces rather than duplicates. Verified against the real config: the existing `CapsLock -> Ctrl+B (herdr prefix)` rule survived, two consecutive runs left one copy, and `karabiner_cli --lint-complex-modifications` reports the rule ok.

**What was verified and what was not.** `F19` opens the search window: proven by posting a synthetic `F19` through System Events and capturing the resulting window. Rebinding live is proven too, by driving the real recorder control with a scripted click and a modified key event: `⌥⌘J` recorded, `F19` then fires nothing, `⌥⌘J` fires, Delete resets to `F19` and it fires again, all in one process with no relaunch. **The physical `fn` to `F19` link was not verified**, and cannot be from here: Karabiner seizes the physical keyboard at the IOKit HID layer, well below where a synthetic `CGEvent` is injected, so no scripted event can exercise the rule. It needs a finger.

**The globe key question is answered structurally rather than empirically.** The rule forwards `fn` through (`to: [{"key_code": "fn"}]`) on purpose, so `fn`+arrow, `fn`+delete and `fn`+`F1` keep working. Karabiner has to decide what to emit at key-down, before it can know whether the tap will turn out to be alone, so there is no way to suppress `fn` only for a bare tap. macOS's globe-key action therefore fires on the forwarded tap unless the user turns it off in System Settings, Keyboard, "Press the globe key to", or with `defaults write com.apple.HIToolbox AppleFnUsageType -int 0`. Whether Karabiner's *virtual* keyboard triggers that action at all is the one unknown, so the README says to try it and only change the setting if the picker appears. `AppleFnUsageType` is unset on this machine, so it is on the system default.

Rejected: dropping the `fn` forward on the second tap only. It would stop the second tap re-triggering the picker, but the *first* tap has already triggered it, so it buys nothing and costs `fn` as a modifier during the double-tap window.

### A settings window

`HerdSettingsWindow` plus `HerdSettingsView`, covering all eleven preferences: the shortcut, `herdEnabled`, `herdPollInterval`, `herdNotifyOnBlocked`, `herdPopupEnabled`, `herdPopupDuration`, `herdSessionFilter`, `herdTerminalBundleId`, and three new ones (`herdStampWindowTitles`, `herdRemoteEnabled`, `herdRemotePaths`). 400 pt wide and about 660 pt tall, which fits a four-session herd with no scrolling.

The previous build's argument against a window was that it "would mean a second `NSHostingController`, a title bar, and an activation policy fight with `LSUIElement`". Two of those are free and the third is the `NSApp.activate()` the search window already does. What a popover genuinely could not do is hold a text field and a recorder, because a `.transient` popover dismisses on the first click outside itself.

Two things this fixed rather than merely relocated:

- **The session list shows every discovered session, including ones the filter is hiding.** The menu built its list from the *filtered* snapshot, so unticking a session removed it from the menu and there was no way back short of clearing the whole filter. The list now comes from `HerdSessionRoster`, a small observable the model publishes from the unfiltered snapshot. It is a separate object rather than another `@Published` on `HerdBarModel` so the form does not re-evaluate its body at the poll rate, which would also have been a way to lose a half-typed path.
- **`acceptsFirstMouse` on the recorder.** AppKit spends the first click into an inactive window on activation, and an accessory app's settings window is usually not active. Without this the recorder needed two clicks with nothing explaining the first. Found by driving it from the harness, which hit exactly the bug a user would have.

The right-click menu is down to four entries: Find a pane (which is where the shortcut is announced, and which says "shortcut unavailable" when registration failed), Watch herd sessions, Settings, Quit. Registration failure is now visible in two places instead of only on standard error, which a user launching from the Finder never sees.

`HerdPreferences` became an `ObservableObject` whose setters announce, which is the whole of the live-apply plumbing: the app delegate takes one subscription and re-registers the shortcut when it differs, refreshes the status item (the paused glyph is the one thing a poll cannot publish, since turning polling off is what stops the polls), and re-polls, so adding a socket path does not wait out the five-second idle back-off.

### Remote sessions, the light version

Established rather than re-derived: `herdr --remote <ssh-target>` is an attach mechanism (`src/remote/unix.rs`, "ssh bridge stdin/stdout", `HERDR_REMOTE_KEYBINDINGS`), so the remote session's socket is on the remote host and `HerdrDiscovery` scanning `~/.config/herdr` will never see it.

`ssh -L /local/path:/remote/path` forwards a Unix domain socket to a local path, so the feature is: let the user configure extra socket paths or directories, scan them, and flag what is found. No new protocol code, nothing to keep in sync with herdr, no SSH lifecycle management. `HerdrDiscovery.extraPaths` does the scan; `HerdSession.isRemote` carries the flag.

Three requirements drove the parts that are not obvious:

- **Visually distinguishable.** A `remote` marker beside the session name, reusing the exact mechanism the `no terminal` marker already uses, so the column measurement follows for free and a local-only herd pays nothing for the word. Not a third accent, per `DESIGN.md`. Both markers can appear together and the column reserves room for both.
- **A dead forward fails as fast as a stale local socket.** It does, for the two common cases: no socket file, or a socket file with nothing listening, are both refused at connect in microseconds and render as `remote  not reachable`. The row stays rather than vanishing, which is the same rule stopped local sessions follow, and the placeholder says "not reachable" rather than "stopped" because what failed could be the tunnel, the far host, or the server on it and the panel does not know which.
- **One unreachable remote must not degrade the local sessions.** This is what forced `HerdSnapshotBuilder` to stop populating sessions with a `map`. The one slow failure mode is a blackholed network: `ssh` accepts on this machine before discovering the far side is gone, so the socket is reachable and silent, and the call runs its budget out. Sequentially that budget is added to every snapshot. Sessions are now populated with `DispatchQueue.concurrentPerform`, so the build costs the slowest session rather than the sum, and remote sessions get a 700 ms call budget against a local session's 2 s. Since `populate` aborts on the first failure, 700 ms is the whole worst case for one dead remote. There is a timing test for it.

Also: a remote session's row does not raise a terminal, because every local terminal is showing something else and raising one would be the same lie the pre-attachment-probe build told. Name collisions are disambiguated with a numeric suffix and the local session keeps the plain name, because names are the session filter's keys and SwiftUI's row identities.

**Tested on a loopback, not on a second machine, and not through `ssh` itself.** A local Unix-socket relay forwarded `sessions/hail_mary/herdr.sock` to `/tmp/herd-remote/prod_api.sock`, plus a bound-and-abandoned socket at `/tmp/herd-remote/prod_dead.sock` standing in for a dead tunnel. Both were discovered, marked `remote`, and rendered correctly: `prod_api` with its six agents, `prod_dead` as `remote  not reachable`. `ssh -L` against `localhost` was not used because sshd here has no `authorized_keys` and adding one is a change to the user's SSH authentication that should not happen without asking. From discovery's side the two are the same thing, a Unix socket at a path outside the config root proxying to a herdr server.

### Quality floor, measured

- **Rows reconcile.** With the filter cleared: `default` 8, `hail_mary` 6, `oncall_20-23_07` 2, so 16 local agents, and the panel printed 16, plus `shara_oncall_2-6_07` as `stopped` and both forwarded sessions. One trap for anyone re-running this: a bare `herdr agent list` from inside a herdr pane hits the *ambient* session via `HERDR_SESSION`, not `default`. It reported 6 for `default` and sent this check off for ten minutes. Use `herdr --session default agent list`.
- **Idle CPU with the panel open**, from `ps` over 80 seconds: **0.300 %** of one core in the shipped configuration (four local sessions, remote scanning off, 1 Hz). With two forwarded remotes added, six sessions with one proxied through a Python relay, 1.05 % over 75 seconds. The concurrency change costs nothing measurable.
- **Tests: 52 in `HerdKit`** (up from 45: five for remote discovery, two for remote failure behaviour including the timing one) **and 26 in the `BoringHerdBar` package** (15 `HerdPanelUITests`, up from 13 for the two marker-measurement tests, plus 11 new `HerdShortcutTests` for persistence, validity and display).

## Fifth pass, 2026-07-31: an `EINVAL` that was not the timeval, and a marker that was sizing the whole panel

### `setsockopt(SO_RCVTIMEO) failed: Invalid argument`

The live panel printed `hail_mary  socket unavailable: setsockopt(SO_RCVTIMEO) failed: Invalid argument` in place of that session's six rows. Intermittently: a cold launch competing with startup showed it, a warm run did not.

**The standing hypothesis was wrong, and it is worth recording why, because it was extremely plausible.** `HerdrClient` now runs one monotonic end-to-end deadline and hands each phase `Deadline.remaining`, so a call whose connect and write consume the whole budget reaches the read phase with nothing left, and a non-positive `timeval` looked like the obvious culprit. It is not, for two independent reasons, both established by probing the kernel from a throwaway binary rather than by reading the code:

- A non-positive or out-of-range `timeval` is rejected with **`EDOM`**, "Numerical argument out of domain", not `EINVAL`. Verified for `tv_sec = -1`, `tv_usec = -1` and `tv_usec = 1000000`. `MemoryLayout<timeval>.size` is 16 on arm64, which matches `sizeof(struct user64_timeval)`, so the other classic `EINVAL`, a short `optlen`, was not in play either.
- The read path already floored the value at a millisecond, so a non-positive figure could not reach the syscall at all.

**The real cause is that the peer had already closed.** Darwin's `sosetopt()` refuses *every* socket option once a socket is fully shut down, and a Unix stream socket becomes fully shut down the instant its peer closes, because `soisdisconnected()` raises `SS_CANTRCVMORE` and `SS_CANTSENDMORE` together. It reports that refusal as `EINVAL`. A herdr server writing its response line and closing is the *ordinary* end of an exchange, so the per-read `SO_RCVTIMEO` install failed against a socket that was working perfectly, and the reply already sitting in the receive buffer was discarded as a broken socket. The intermittency is the race it sounds like: whether the peer's `FIN` is processed before or after the client reaches `read()`.

Proven with a `socketpair` probe (`setsockopt` after `close()` on the peer returns `EINVAL` 22, and `recv` on that same socket still returns the buffered bytes) and then pinned with a real one-shot `AF_UNIX` server in `HerdKitTests`, which reproduces the exact error string before the fix and passes after.

Three changes, none of which weaken the check that exposed this. **Checking `setsockopt`'s return value was right and stays.**

- `UnixSocketConnection.read` answers a non-positive budget with `HerdrError.timeout` **before any syscall**. The old floor quietly bought a millisecond the caller had not granted, which made the advertised timeout an upper bound plus a phase. Its regression test deliberately leaves a response waiting in the receive buffer, because only a read that times out *despite* readable data has actually honoured the deadline; a clamp would return the bytes and pass a weaker test.
- The install tolerates exactly one failure: the peer having hung up, confirmed positively with a zero-timeout `poll` for `POLLHUP` rather than inferred from `errno`, so a genuinely bad option still throws. Safe against the hang the check exists to prevent, because `recv` on a hung-up socket cannot block.
- Blast radius. One socket fault used to erase a whole session, so `populate` now fails no further than the call that failed. Only `agent.list` is fatal, and it is retried once for a fault a fresh connection can fix (`socketUnavailable`, `protocolError`) and never for a timeout, which has already spent the budget it would need. `workspace.list` joins `tab.list` as best-effort: losing it costs the workspace *label*, not the rows, since `group(agents:into:)` already synthesises a workspace for any id the reply did not mention. All three calls now share **one** budget and are made in order of importance, which both keeps one dead session at one `timeout` however many of its calls fail (the property `remoteCallTimeout` is sized against, and which per-call budgets would have tripled the moment the supporting calls stopped being fatal) and gives `agent.list` first claim on it.

This corrects two sentences in the fourth pass: `populate` no longer "aborts on the first failure", and the 700 ms worst case now holds because of the shared deadline rather than because of the abort.

### The `no terminal` marker was sizing the `SESSION` column for every row

`no terminal` printed beside the session name, inside the `SESSION` cell, so it was part of what the column was measured from, and it was the widest thing that column ever held. The user's own herd is the worst case for that rule, because the detached session also has the longest name: at the 13.5 pt default the marker and its gap were 75.5 pt of a 195.5 pt column, so all sixteen rows paid 75.5 pt to say one thing about one session. The panel came out 640 pt wide with roughly 140 pt of dead space between every session name and the workspace beside it.

**The markers now print on their own line, indented under the session name**, outside the grid, at a line height well under a row's. Four options were weighed and three rejected on the captures:

- *Overflow into the unused space to the right.* Rejected, and this is the one that looks right until it is measured. With the column sized from names only it is 120 pt at the default, the marked name is 107 pt of that, and the marker would run from 147.5 pt to 215.5 pt while the workspace column starts at 153 pt and its text `services` runs to 210 pt. It overlaps the workspace text almost exactly. It is only ever safe by luck, because the session with the marker is often the one with the longest name.
- *Right-align it in the column.* Does not help: the marker is still measured, so the column is still inflated.
- *A symbol with the words on hover.* Cheaper but still measured, and it trades a plain-language fact for a glyph on the one surface whose whole reason for existing is that the user could not tell why clicking did nothing.
- *Its own line.* Costs one short line of height per marked session and gives back about 75 pt of width, which is the right way round for a panel that must not scroll. It follows this file's own precedent: a stopped session already prints as a free line outside the grid, because "a line that is not a row should not pretend to be one". The words stay, so the contrast floor still applies and is still met at `textTertiary`, 5.21:1.

The guarantee is structural rather than arithmetic: `HerdLedgerColumns.measuring` now takes `sessionNames: [String]` and the `SessionCell` type is gone, so there is no longer any way to pass a marker into the measurement. Marker lines carry `agent == nil` and are excluded by the same filter that already excluded stopped sessions' stand-in lines.

### Quality floor, measured

- **Rows reconcile 16/16.** `herdr --session default agent list` 8, `--session hail_mary` 6, `--session oncall_20-23_07` 2, and the panel printed exactly those, plus `shara_oncall_2-6_07` as `stopped` (its socket refuses at connect). No session errored in any capture. The `HERDR_SESSION` trap from the second pass still applies: name each session explicitly.
- **Dark-mode captures at three steps, all four sessions present, none erroring:** 441 × 318.5 pt at 10.5, **564.5 × 410 pt at the 13.5 default**, 688 × 491.5 pt at 16.5. Down from 640 × 396 pt at the default before this pass: 75.5 pt narrower and 14 pt taller, the height being the marker line.
- **Nothing scrolls at any step.** The body cap scales with the type (420 / 540 / 660 pt) against a body needing 294 / 381 / 460.5 pt, so the marker line is absorbed with room to spare at every step.
- **Idle CPU with the panel open**, from `ps` over 75 seconds: **0.53 %** of one core, four local sessions, remote scanning off, 1 Hz. Same order as the 0.300 % recorded in the second pass; the herd was busier, and there is still no animation anywhere.
- **Tests: 58 in `HerdKit`** (up from 52: three for the socket-option and deadline behaviour against a real one-shot server, three for the blast-radius policy) **and 36 in the `BoringHerdBar` package**, with the four tests that asserted the marker *was* paid for in the session column replaced by three asserting it is not, plus one pinning the guarantee at every step of the type scale.
