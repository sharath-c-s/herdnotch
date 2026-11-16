# Gotchas

Each item was verified on a device or with a probe. Read the section for the subsystem you change.

## Notch effect layer (glitch-free)

1. A pure reducer with passing tests is not enough. Half of the stuck-open and flicker bug class lives in AppKit effect contracts.
2. Run timers in `RunLoop.Mode.common` (or use `DispatchSourceTimer`). A default-mode `Timer` freezes during scroll momentum, drags and menu tracking, so the exit grace never fires and the panel sticks open.
3. Do not trust `mouseExited` once expanded. Fast flicks miss it, and a window that grows under a still cursor sends phantom entered/exited pairs. Use global plus local `mouseMoved` monitors (a global monitor is silent for your own window) and remove them on collapse-settle, or idle CPU rises.
4. Every animation carries a generation token. A stale completion must do nothing, or an aborted collapse marks state collapsed under an expanded panel.
5. The scroll-momentum lock needs the app to send `scrollMomentumBegan/Ended`. That happens in `NotchPanel.sendEvent`; without it a trackpad fling collapses the panel mid-scroll.
6. AppKit sends `draggingEnded` for an Esc-cancelled drag and for a drop onto nothing. Release drag locks there too.

## AppKit and macOS

1. MediaRemote now-playing READ is gated to Apple-signed callers. An ad-hoc-signed app gets an empty dict (keys=0). `MRMediaRemoteSendCommand` is not gated. Never compile `HelperScripts/mediaremote-helper.swift` into the app: compiling and ad-hoc signing it brings the gate back.
2. `NSEvent.addLocalMonitorForEvents` fires only while `NSApp.isActive`. A `.nonactivatingPanel` can be key without the app being active. Override `NSWindow.sendEvent(_:)` on the panel instead.
3. SwiftUI `.onKeyPress` and `.onMoveCommand` never see arrow keys while a `TextField` field editor is first responder. Use the `sendEvent` override.
4. A keyboard-selected row needs a distinct highlight (status-coloured ring), not the mouse `hoverFill`.
5. Carbon hotkeys: every `HerdGlobalHotKey` instance needs its own `EventHotKeyID.id`, and a handler must return `eventNotHandledErr` for ids that are not its own. With a shared id, the last-installed handler swallowed the search hotkey.
6. Apple events need `com.apple.security.automation.apple-events` under the hardened runtime. Without it `NSAppleScript` returns `-1743` with no consent prompt and no log. A `with timeout` shorter than the consent dialog kills the dialog, and TCC records a permanent denial. `build-notch.sh` checks the entitlement; keep that check.
7. Test Apple events only with `open` on the bundle. A binary run from a shell inherits the terminal's automation grant and hides the bug.
8. Keychain items bind to the code signature. Ad-hoc signing makes each rebuild a new app for Keychain and TCC.
9. Ad-hoc signed apps cannot post system notifications. The toast and the edge glow are the alerts.
10. `volumeAvailableCapacityForImportantUsageKey` wakes every cache-delete service on each call (log flood, 13.7% idle CPU). Use `volumeAvailableCapacityKey`.
11. `proc_pidinfo` cannot read root or other-user processes. `/bin/ps` (setuid root) can.
12. On macOS 27 the window-server owner name is "Herd Notch", not "HerdNotch". Match windows by pid.
13. Assigning `Process.standardOutput` after `launch` throws an NSException. Cleanup in `willTerminate` inside a `Task` never runs, which orphaned the perl child.
14. Any SwiftUI animation in flight over a panel can keep a transaction pending forever, so `GraphHost.flushTransactions` runs every run-loop pass and a core goes to 99%. Measure idle CPU after any motion change. The wing icons animate since 0.1.7, and their own cost was never measured apart from the whole app.
15. Darwin `setsockopt` fails with `EINVAL` on a fully shut-down socket, and a Unix stream socket is fully shut down when the peer closes. A per-read timeout set after the peer closed discarded a reply that was already buffered.

## herdr and agent data

1. herdr tab labels are now plain digits per workspace. Never use a tab label as an identity key, and do not show a digit label as a name.
2. An agent that finishes in the focused herdr pane goes to `idle`, not `done`. This is herdr behaviour.
3. HerdNotch never reads herdr's notification stream. herdr `[ui.toast] delivery = "off"` does not affect it.
4. `herdr-client.sock` is created by the server, not the client. It does not prove a client is attached.
5. `~/.claude/sessions/<pid>.json` `procStart` is UTC. A local-time parse hid every local Claude session while all tests passed.
6. Sessions started with another `CLAUDE_CONFIG_DIR` (for example aim profiles) write their registry elsewhere, so the registry join misses them.
7. Anthropic's usage endpoint answers 429 with `Retry-After: 0` while it still throttles. Two pollers on the same token double the load.
8. A Claude `PermissionRequest` hook runs at the same time as the terminal dialog. A terminal "Yes" runs the tool but does NOT stop the hook process (Esc does). A pending notch card must therefore be released by the sweep (session no longer blocked), not by the hook connection closing.
9. Claude's menus in `pane.read` text come in two shapes: numbered (`❯ 1. Yes`, with option descriptions on deeper-indented lines) and unnumbered (`❯ No, exit` plus sibling lines). Lines can be about 150 columns wide. Claude selects a numbered option on the digit key alone.
10. A key sent with `pane.send_keys` lands on whatever prompt is on screen at that moment. Read the pane again right before the send, compare the prompt fingerprint, and refuse a second send at the same pane `revision` (a double click arrives before the agent redraws).
11. Agents can drive a real Claude or Codex TUI for checks: `herdr tab create --cwd <dir> --no-focus`, `herdr pane run <pane> "<cmd>"`, `herdr pane wait-output <pane> --regex <re>`, `herdr pane read <pane> --source visible`, `herdr pane send-keys <pane> 1|esc|enter`. A new folder first shows the trust menu.
12. Hook stdin and `pane.read` captures contain home paths, usernames and project names. Scrub them before a capture becomes a test fixture: this repo is public.

## Toolchain and shell

1. `swift build` and `swift test` need full Xcode (SwiftUI and Testing macros). Command Line Tools fail with `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found` or a missing `Testing` module. Set `DEVELOPER_DIR`.
2. In zsh, `log` is a builtin. Use `/usr/bin/log`.
3. zsh does not word-split an unquoted variable in `for f in $FILES`. Use `while read`.
4. BSD `sed` with `\n` in the replacement does not insert a newline. Use perl.
5. brew reads its local tap clone, which syncs only on auto-update. `release.sh` refreshes it; without that, `brew upgrade` says the latest version is installed.
6. A cask `uninstall delete:` for a root-owned file runs with sudo on every upgrade and fails without a tty.
7. Look at captures, not only at numbers. A consistent measurement once hid an errored session.
8. Agents cannot screen-record. For visual checks, set `HERDBAR_DUMP`, `HERDBAR_POPUP_DUMP`, `HERDBAR_SETTINGS_DUMP` (see `HerdHost/HerdDebugCapture.swift`, `HerdSettingsWindow.swift`) or `HERDNOTCH_PREVIEW_DUMP=<dir>` (preview card states at default and minimum agents-card size, `HerdNotch/PreviewDebugDump.swift`) and open the PNGs.
9. Agents cannot synthesize `F19` with `osascript` (TCC Input Monitoring denies it). Hotkey checks need the user.
10. Deleting an ignored syscall return check is not a fix. The `SIGPIPE` and `setsockopt` bugs showed up because return values started to be checked. Keep the checks and fix the cause.
11. `Substring.count` and `String.count` are O(n). A `while rest.count > width` wrap loop is quadratic, and a 1 MiB hook request froze the main thread in review. Walk indices with `index(_:offsetBy:limitedBy:)` and cap untrusted input before any per-render work.
