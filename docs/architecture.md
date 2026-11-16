# Architecture

HerdNotch is an unsandboxed macOS app that draws a panel in the MacBook notch. It shows AI coding agents (Claude Code, Codex) from herdr and from local session files, plus now playing, reminders, keep-awake, battery, plan usage and system health. It has no Xcode project: SwiftPM builds it, and `HerdNotch/build-notch.sh` assembles and signs the `.app` by hand.

## Packages and targets

| Package / target | Kind | Job | Must not |
|---|---|---|---|
| `HerdKit` | library, pure Foundation | herdr socket client (`agent.list`, `workspace.list`, `tab.list`, `*.focus`, `pane.read`, `pane.send_keys`), local Claude/Codex agent sources, Claude session registry join, transcript activity, approval core (hook protocol, approval socket server, `ApprovalBook`, `PanePrompt`, `PreviewRoute`) | import any UI framework |
| `HerdNotch/Sources/HerdPanelUI` | library | Ledger rows, palette, panel styles | import anything but SwiftUI and HerdKit (keep AppKit in host files) |
| `HerdNotch/Sources/HerdShortcut` | library | Shortcut model and display names | |
| `HerdNotch/Sources/HerdHotKey` | library | Carbon global hotkeys | share one hotkey id between instances |
| `HerdNotch/Sources/NotchCore` | library, pure logic | Interaction reducer, battery alerts, shelf, keep-awake core, long-task rule, health report, system load math, live-activity state | touch AppKit; it carries most of the tests |
| `HerdNotch/Sources/NotchGeometry` | library, pure logic | Bento and Health layout math, notch metrics | |
| `HerdNotch/Sources/HerdHost` | library | Settings views, search, focus service, terminal window locator (iTerm2, Terminal, tmux, IDE) | |
| `HerdNotch/Sources/UsageKit` | library | Claude, Codex, OpenCode and Antigravity usage readers | write or refresh a credential |
| `HerdNotch/Sources/UsageProbe` | executable | Manual usage probe | run in a loop (throttled endpoint) |
| `HerdNotch/Sources/HerdNotch` | executable | Window controller, animator, panel, services, pages | hold decision logic: an executable target cannot be unit-tested |

Rule: put every pure decision in `NotchCore`, `NotchGeometry` or `HerdKit` so that tests reach it. The `HerdNotch` target only wires effects.

## Notch shell (glitch-free core)

1. `NotchCore/NotchInteractionReducer.swift` is a pure reducer. Each event returns a COMPLETE, display-tagged `[NotchCommand]` list, including forced collapse of other displays.
2. The controller (`NotchWindowController`, `NotchCommandExecutor`) is a dumb per-display executor. It does no state diffing.
3. The window has a fixed size. `NotchAnimator` animates a CALayer mask, never the window frame. Each animation carries a monotonic generation token; a stale completion is a no-op.
4. Hover uses global plus local `mouseMoved` monitors with hysteresis against the target frame in screen coordinates. Monitors are removed when the collapse settles.
5. `NotchPanel.sendEvent` intercepts keys (search arrows) and scroll momentum for the nonactivating panel.
6. Page state (Herd, System, Health) lives in the view model (`NotchDisplayViewModel`), not in the reducer.

## Agent data flow

1. `AgentSourceMerge.snapshot` (HerdKit) builds one snapshot per poll (1 Hz). Mode is herdr only, local only, or both.
2. herdr agents come from `agent.list`; tab labels join from `tab.list` on `tab_id`.
3. Local Claude agents come from `~/.claude/sessions/<pid>.json` (`procStart` is UTC). Codex comes from `~/.codex/sessions` rollouts through `CodexRolloutTracker` and from running `codex` processes. In both mode, a local agent with a herdr ancestor process or a session id that herdr already reports is dropped.
4. The registry name joins on `agent_session.value` (the Claude session UUID). `HerdAgent.displayName` order: registry name set by `user` or `auto`, then claude's terminal title (only when claude set it), then a non-numeric tab label, then a `derived` registry name, then the cwd basename.
5. `NotchHerdModel` diffs status per agent (keyed on session name plus pane id) to fire toasts and the screen-edge glow. Toast rules: herdr `done` always toasts; a working-to-idle landing toasts only past the long-task threshold (`LongTaskRule`).
6. Activity (now-doing line, context ring, subagent badge, pending ask) comes from `~/.claude/projects/*/<uuid>.jsonl`. The reader tails 2 MiB, then reads only appended bytes, and re-tails when it falls more than 2 MiB behind. Subagents are counted from `<uuid>/subagents/agent-*.jsonl`.
7. Remote herdr sessions: forward the remote `herdr.sock` with `ssh -L` to a local path and list it under extra socket paths. Remote rows show status only, because transcripts stay on the server.

## Other services

- Now playing: primary read path is the vendored ungive/mediaremote-adapter run by Apple-signed `/usr/bin/perl` (`NowPlayingAdapterProcess`). Fallback is `HelperScripts/mediaremote-helper.swift` run by `/usr/bin/xcrun swift`. Transport commands call MediaRemote in-process.
- Keep-awake: manual hold, timer, and condition holds (busy agents, apps, charger, external display). Lid-closed mode uses a sudoers rule plus `pmset`.
- System load and Health: sample only while the System page (summary) or Health page (full) is open. Root and other-user processes are read through setuid `/bin/ps`.
- Usage: read-only credentials (Keychain through `/usr/bin/security`, CLI auth files).
- Release: `scripts/release.sh <version>` builds, uploads a GitHub release on `sharath-c-s/herdnotch`, and bumps the cask in `sharath-c-s/homebrew-tap`.

## Older design docs

`docs/herd/DESIGN.md` (visual direction), `docs/herd/FEATURES.md` and `docs/herd/PLAN.md` describe the menu-bar predecessor (BoringHerdBar). Their colour, type and motion rules still apply to the ledger rows. Their phase plans are history.

## Notch approvals (preview card)

1. A plain click on an agent row opens a preview card under the row. A Command-click jumps to the agent and collapses the notch, as before. Search rows and the Health page always jump.
2. Claude sessions: a user-level `PermissionRequest` hook runs `HerdNotch.app/Contents/MacOS/HerdNotch --claude-permission-hook`. This mode exits before `NSApplication` starts. It sends the hook stdin as one NDJSON line to `~/Library/Application Support/HerdNotch/approvals.sock` (mode 0600) and prints the reply line. When the app does not run, the hook prints nothing and Claude shows its normal dialog.
3. `ApprovalSocketServer` (HerdKit) holds each connection until a decision. `ApprovalCenter` (app) keeps an `ApprovalBook` keyed by Claude session id, which equals `HerdAgent.agentSessionID`. A reply is `HookOutput.render` of `allow`, `always` (echoes the first permission suggestion), `deny`, `answers` (AskUserQuestion, one single-select question only) or `passthrough` (empty line).
4. The terminal dialog shows at the same time as the hook. A terminal answer does not stop the hook process, so each poll calls `ApprovalBook.sweep`: it releases a request whose session is not blocked for 2 s (after a 2 s grace), and a request whose session is not in the roster after 3 s.
5. herdr panes without a hook request (Codex, remote herdr, no hook installed): the card shows `pane.read` text and the menu that `PanePrompt` parses. A button sends `pane.send_keys` only if the prompt fingerprint is unchanged on a fresh read.
6. Cost: one `pane.read` per poll, only for the expanded herdr row, only while the panel is open. Nothing runs while the notch is collapsed.
7. Install: `scripts/install-claude-hook.sh` merges the hook into `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` with a backup. `--uninstall` removes it. Settings > Agents shows the hook status and an off switch (`herdNotchApprovals`).

