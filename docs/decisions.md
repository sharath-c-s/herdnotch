# Decisions

Each row: the decision, why, and when. Newer rows win over older ones. Rows marked SUPERSEDED stay for the reason.

## Product and platform

| Date | Decision | Why |
|---|---|---|
| 2026-07-31 | Standalone app, not a tab in a boringNotch fork | Xcode was not installable then, and two apps cannot share one notch (same window level). |
| 2026-07-31 | Poll herdr at 1 Hz, no event subscriptions | `pane.agent_status_changed` is pane-scoped, so push needs per-pane subscriptions and re-subscribe on every pane create and close. One round trip is about 36 ms. |
| 2026-07-31 | `HerdKit` is pure Foundation | It builds and tests without UI, which made the risky half verifiable first. |
| 2026-07-31 | `HerdPanelUI` is its own target with only SwiftUI and HerdKit imports | Keeps host types out structurally. It does not stop `import AppKit`; keep AppKit in host files. |
| 2026-07-31 | Amber for blocked, not red | A blocked agent has not failed; it waits for you. |
| 2026-07-31 | Search shortcut: register `F19`, Karabiner maps double `fn` to it | Carbon cannot register `fn`. No Apple keyboard has `F19`. Avoids the Input Monitoring permission a `CGEventTap` needs. |
| 2026-07-31 | Remote herdr through `ssh -L`, no SSH code in the app | `herdr --remote` is an attach mechanism; the socket lives on the far host. A forwarded local path works with existing discovery. |
| 2026-07-31 | `client.window_title.set` `reason == "no_foreground_client"` is the attachment probe | An unchanged title has benign causes, so `!changed` is not a probe. |
| 2026-07-31 | Ledger view over Marquee | User choice. |
| 2026-09-09 | Unsandboxed, no XPC | Direct herdr sockets, AppleScript, EventKit and IOKit. |
| 2026-09-09 | Pure reducer emits complete display-tagged commands; controller executes only | Glitch logic becomes unit-testable; no diffing in the effect layer. |
| 2026-09-09 | Fixed-size window, animate a CALayer mask | Frame animation resizes the backing store and re-lays-out SwiftUI each frame. |
| 2026-09-09 | Search arrow keys through `NotchPanel.sendEvent` | See gotchas: field editor and local monitors both fail. |
| 2026-09-09 | Caffeinate hotkey Control+Shift+C | Double-tap Control collides with macOS Apple Intelligence voice typing. |
| 2026-09-09 | Drop the Ice-style menu-bar manager | Cross-process menu-bar access is AX-gated and has no reposition API (`HerdNotch/ICE-FEASIBILITY.md`). |
| 2026-10-14 | Agent activity joins `agent_session.value` to `~/.claude/projects/*/<uuid>.jsonl` | Exact 1:1 key already in herdr's payload; no hooks, no process scan. |
| 2026-10-14 | Count subagents from `<uuid>/subagents/*.jsonl` | Background agents return their `tool_result` at once, so tool_use pairs undercount. |
| 2026-10-14 | Skip `<synthetic>` and zero-usage rows for context | They are written on API errors and zeroed the context ring. |
| 2026-10-14 | Context limit: 1M if the requested model has `[1m]` or usage ever passed 200k, else 200k | Transcript does not record the window size. Read `requestedModel`; `message.model` drops the `[1m]` tag. |
| 2026-10-14 | Panel width floor 720 | Top-band widgets overlap the 200 pt notch dead zone below 720. |
| 2026-10-14 | Shelf drag lock releases in `draggingEnded` and `draggingExited`; the drop handler releases it too | Esc-cancel sends `draggingEnded`, not `concludeDragOperation`. Do not rely on SwiftUI resetting `isTargeted`. |
| 2026-10-14 | Keep the `ShelfService` snapshot sequence guard | Separate Tasks resume on the main actor in no fixed order. |
| 2026-10-14 | Browse list: every live agent, blocked first, recency inside a status | User asked for every live agent. Pure recency order was asked about and not answered. |
| 2026-10-18 | herdr optional: sources herdr, local, or both | Open-source users may not run herdr. |
| 2026-10-18 | MIT license; no Vorssaint (GPL) code; OpenUsage and mediaremote-adapter used with attribution | Keep the app MIT. See `NOTICE.md`. |
| 2026-10-18 | Usage credentials are read-only; never refresh or write | Refreshing would log the user out of the Claude and Codex CLIs. |
| 2026-10-18 | Usage rate limits behave like OpenUsage, reimplemented: `Retry-After` or 300 s cooldown, keep last good reading, reuse an answer for 6 min on non-forced refresh, one Keychain read per service | User directive. Escalating 5 to 30 min backoff was rejected. |
| 2026-10-18 | Now playing: perl + mediaremote-adapter first, `xcrun swift` helper as fallback | Works without Xcode Command Line Tools. SUPERSEDES 2026-09-09 "xcrun helper only". |
| 2026-10-18 | Manual keep-awake off snoozes condition holds until they go false | The hotkey did nothing while a condition held. |
| 2026-10-18 | Lid sudoers rule is removed only on `brew uninstall --zap` or from Settings | A cask `uninstall delete:` made every upgrade ask for sudo. |
| 2026-10-18 | herdr `done` always toasts; the long-task threshold adds the duration; local idle landings need the threshold | Keep existing alerts and avoid noise from local idles. |
| 2026-10-18 | Page state in the view model, not the reducer | No reducer change for a page switch. |
| 2026-11-07 | Develop in public `sharath-c-s/herdnotch`; private `bar-for-herd` archived | Private history holds the GPL attic and personal paths. |
| 2026-11-07 | Keep bundle id `com.boringherd.HerdNotch` | Changing it resets settings, TCC permissions and Keychain access. |
| 2026-11-07 | `/graft/` is in `.gitignore` | graft re-creates it on every build; `release.sh` refuses a dirty tree. |
| 2026-11-07 | Wings: the mask keeps wings for every presentation except suspended; the hover view widens only when collapsed | Avoids a collapse-to-cutout jump; a wide hover view over the open panel eats band clicks. |
| 2026-11-07 | Health never quits or kills anything; agent processes never get a quit hint | User choice. Agents are jumped to, not quit. |
| 2026-11-07 | Root and other-user processes through setuid `/bin/ps` | `proc_pidinfo` cannot read them; Jamf Protect and WindowServer were the hidden CPU. |
| 2026-11-07 | Memory used = (internal - purgeable) + wired + compressed; per process = `phys_footprint` | Matches Activity Monitor; RSS hid swapped memory. |
| 2026-11-07 | Big-app suggestion only under memory pressure, swap, or 85% used, and impact < 80 | Otherwise the page never says "Nothing to improve". |
| 2026-11-07 | Sample load only while System or Health is open | No background cost. User declined always-on load alerts. |
| 2026-11-07 | Disk free from plain `volumeAvailableCapacityKey` | The "important usage" key wakes every cache-delete service on each call. |
| 2026-11-08 | Agent name: claude terminal title beats tab label and `derived` registry name; all-digit tab labels are skipped | herdr now labels tabs 1, 2, 3, and sessions under another `CLAUDE_CONFIG_DIR` have no registry entry. The user asked for the session name. A tab the user renamed now loses to Claude's title (accepted). |
| 2026-11-08 | Status recency keyed on session name plus pane id | herdr numbers tab labels per workspace, so a label key merged agents across workspaces, reset long-task timers and re-fired toasts. |
| 2026-11-16 | Claude approvals through a `PermissionRequest` hook, not keystrokes | The hook gives the tool name and input, and the reply goes to the correct session by id. Keystrokes into a pane can hit the wrong prompt. A spike showed allow, always, deny and AskUserQuestion answers all work. |
| 2026-11-16 | The hook client is the app binary in `--claude-permission-hook` mode | No extra helper to sign or ship. It exits before AppKit starts, and any failure prints nothing, so Claude falls back to its own dialog. |
| 2026-11-16 | Keystrokes (`pane.send_keys`) only for herdr panes with no hook request, behind a fingerprint check | Covers Codex and remote herdr. The fresh read before the send stops a key from landing on a different prompt. |
| 2026-11-16 | Plain click previews, Command-click jumps | User choice ("first see a preview and approve things from notch and then go to the session if needed"). Inline expand chosen over a drill-in page. |

| 2026-11-16 | Preview-on-click applies to the Herd browse list only. Search results and the Health page still jump on a plain click | Search is "go there": the user typed a name to reach that agent. Health lists processes, not prompts. |
| 2026-11-16 | Hook decisions go by request token, never by session id. Buttons disarm for 400 ms when the card's route changes | A newer request for the same session can replace the card between render and click. A click must never answer a request the user did not see. |
| 2026-11-23 | Left Command taps reach the app as F17 (triple) and F18 (double) through a Karabiner rule, not a CGEventTap. Delay 350 ms, left Command only | A CGEventTap needs Input Monitoring permission; Carbon hotkeys on a relayed key need none, and the fn fn rule already works this way. 350 ms is long enough to tell two taps from three. Right Command stays a normal modifier. |
