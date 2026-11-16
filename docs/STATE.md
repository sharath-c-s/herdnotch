# State

Last update: 2026-11-16 (0.1.11). Update this file when a release ships or a thread opens or closes.

## Shipped

| Version | Date | What |
|---|---|---|
| menu-bar era | 2026-07-31 | BoringHerdBar menu-bar ledger of herdr agents, `fn fn` search, settings, remote sockets. Retired. |
| phases | 2026-09-09 | HerdNotch notch shell, bento UI, fuzzy agent search, now playing, reminders, caffeinate, toasts, battery, settings. |
| phases | 2026-10-14 | Battery ring and threshold alerts, merged settings, louder toasts with screen-edge glow, transcript activity, remote herdr, panel size, scrolling rows, file shelf. |
| 0.1.0 to 0.1.3 | 2026-10-14 to 2026-10-18 | herdr optional (local Claude/Codex), usage meters, System page, keep-awake with lid-closed mode, power, system alerts, perl now playing, MIT, public repo, brew cask. |
| 0.1.4 | 2026-10-18 | Live-activity wings (now playing, blocked/active agents, battery), track-change announce. |
| 0.1.5 | 2026-10-19 | Agent names from the Claude session registry. |
| 0.1.6, 0.1.7 | 2026-10-27 | Keep-awake cup in the wings; animated icons (waving hand for input, steam, sparkles, moon by reason). |
| 0.1.8 | 2026-11-02 | CPU and memory on the System page. |
| 0.1.9 | 2026-11-04 | Health page (throttling, top processes, swarms by agent, suggestions); plain free-disk read. |
| 0.1.10 | 2026-11-08 | Claude session title instead of herdr digit tab labels; per-pane status recency. |
| 0.1.11 | 2026-11-16 | Preview card on row click; approve Claude prompts from the notch through a `PermissionRequest` hook (allow, always, deny, question answers); herdr pane menus through `pane.send_keys` behind a fingerprint and revision guard; Command-click jumps; bundled `install-claude-hook.sh`. |

Test baselines at 0.1.11: `HerdNotch` 363 (sum of the per-target lines), `HerdKit` 233, `swift build` 0 warnings.

## In flight

Nothing. `main` = `origin/main` at the 0.1.11 commit.

## Open threads

1. On-device E2E for 0.1.11 approvals: allow, always, deny, question answer, Command-click in the live panel, and how long the local registry reports `waiting` while a dialog is open. The release shipped before this check.
2. Re-measure idle CPU on 0.1.10 against 13.7% (0.1.8) and count cache-delete `GetAPFSVolumeRole` log lines against 48 per 10 min. Commands are in `AGENTS.md`.
3. User feedback on the Health page layout. Card fit and switcher width were computed, never seen on screen.
4. Confirm the 0.1.10 toast shows the session name on a real finish or block.
5. Optional, asked but not approved: usage rows per aim profile (reuse `ClaudeUsage` with `CLAUDE_CONFIG_DIR=<profile>/.claude` and `CodexUsage` with `CODEX_HOME=<profile>/.codex`, read-only).
6. Optional, not started: contribute an `aim use` global switch upstream to adrijshikhar/aim (issue first).
7. Optional, ask first: delete about 532 empty `com.boringherd.tests.*` plists in `~/Library/Preferences`.
8. Developer ID signing ($99 a year) for persistent permissions and system notifications: user to decide.
9. Unanswered: browse list "recency order" means blocked-first-then-recency (built) or pure most-recent-first.
10. Not confirmed on device: on-device E2E for shelf drag (Esc mid-drag closes the notch), panel-size sliders with the notch open (mask may snap).
11. Launch at login is not built (no `SMAppService` toggle). Offered in the menu-bar era, never answered.
12. Spotify OAuth (old phase 4) waits on a Spotify developer Client ID. Low priority since system now playing works.

## Known bugs

1. Toast and edge glow can land on the laptop screen while the user works on an external monitor. `collapsedToastTarget()` in `HerdNotch/Sources/HerdNotch/NotchWindowController.swift` picks the first collapsed display from a dictionary. Waiting on the user: were they on the monitor when it happened (2026-10-30, 22:18 and 22:23).
2. Per-pane recency (0.1.10) has no unit test, because it lives in the executable target.
3. Search matches digit tab labels through the herdr-tab field, so typing "1" matches many agents.
4. Sessions under another `CLAUDE_CONFIG_DIR` get only the terminal title as a name; their registry, usage and activity are not read.
5. The `xcrun swift` now-playing fallback needs Xcode or Command Line Tools at runtime.
6. `HerdKitTests.stalledRemoteSessionsDoNotSumIntoTheBuildTime` is timing-bound (`elapsed < 0.72 s`) and fails under machine load (seen at 0.726 s). Rerun before you blame a change.
7. The Claude hook goes only into the config dir the installer targets. Sessions under another `CLAUDE_CONFIG_DIR` get no notch approvals and keep the terminal prompt.

## Next ideas

- Read registries for every aim profile, which would fix known bug 4 and open thread 4 together.
- Pick the toast display from the pointer's or the key window's screen.
- Move recency keying into a testable target.

## Failed approaches (do not repeat)

| Tried | Broke because |
|---|---|
| A preview card drawn as a second box under the unchanged 40 pt row | The empty reserved detail line left a gap, and at the minimum panel size the row scrolled away, so the user could not see which agent they approved. Fixed by one merged block with the name and Jump in its header. |
| Middle-ellipsized commands and single-line option buttons in the card | The user could approve a command they could not read, and Claude's 4-option menu cut labels. Wrap commands with a "N more chars" marker, flow the buttons onto rows, shorten labels at ":" or " · " with the full text in the tooltip. |
| Hook decisions keyed by session id | A newer request for the same session replaced the card between render and click, so an answer click could allow a Bash command. Decide by request token. |
| Install Xcode through Xcodes.app | Apple developer-portal auth returned 401. CLT alone cannot build an `.xcodeproj`. |
| A hairline rail down each session group | Repeated what indentation already said; a 4% luminance step read as a capture artefact. |
| Dimming idle rows toward invisible | Failed WCAG (3.05:1 and 1.28:1). Rule: de-emphasis is relative; the open panel must stay readable. |
| A breathing-opacity working dot | Kept a SwiftUI transaction pending; 99% CPU. Even a finite animation retriggered from the poll cost 18%. |
| Blaming `ScrollViewReader` for that hang | Removing it moved 19% to 15%; nearly innocent. |
| `herdr-client.sock` as the attachment probe | The server creates it. |
| "The `-1712` AppleEvent timeout is a sandbox artefact" | It was the missing apple-events entitlement under the hardened runtime. |
| Non-positive `timeval` or struct layout as the `setsockopt` `EINVAL` cause | Real cause: options are refused on a fully shut-down socket. |
| Judging scroll from panel dimensions only | The shorter capture came from an errored session. Look at the image. |
| `git`-merging a design worktree back | No shared history; the copies predated a CPU fix and would have reverted it. |
| SwiftUI `.onKeyPress` for search arrows | Field editor eats arrows. |
| Local `NSEvent` keyDown monitor for arrows | Fires only while the app is active. |
| In-process `MRMediaRemoteGetNowPlayingInfo` | Empty dict under ad-hoc signing. |
| One autonomous Codex run for a whole feature batch | Died mid-refactor and committed nothing. |
| Ice-style menu-bar manager | AX-gated, no reposition API. |
| Shelf lock release only in `draggingExited` and `concludeDragOperation` | Esc-cancel sends `draggingEnded`; panel stuck open. |
| Setting `lastBatteryPercent` unconditionally | A crossing while the notch was open was never announced. |
| Per-property clamps for battery thresholds | Overlap made the orange tier unreachable; fixed with a cross-clamp and `BatteryAlert.ordered`. |
| Assuming search mode had scroll-momentum wiring | Nothing sent the events. |
| Subagent count from tool_use without tool_result | Background agents get the result at once. |
| Trusting `<synthetic>` assistant rows | Zero usage emptied the context ring. |
| Agent tool `isolation: worktree` | Branches from `main`, not HEAD. |
| Porting OpenUsage code with a script | Permission system blocks copying external code; behaviour was reimplemented. |
| Cask `uninstall delete:` for the sudoers file | Every upgrade needed sudo. |
| Relative paths in a user-run install command | `rm -rf` ran, then `cp` failed in the wrong cwd. Give absolute paths. |
| `git add -u` for a targeted commit | Staged unrelated files. Stage explicit paths. |
| Escalating 5 to 30 min usage backoff | User wanted OpenUsage parity. |
| `CGWindowList` filter by owner "HerdNotch" | macOS 27 reports "Herd Notch". |
| `swift build` with Command Line Tools only | Macros need Xcode. |
| `volumeAvailableCapacityForImportantUsageKey` | Woke every cache-delete service. |
| Release with a stale local tap | brew said the latest version was installed. |
| Tab label as the recency key | herdr numbers tabs per workspace; agents collided. |
