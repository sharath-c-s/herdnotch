# bar for herd

A macOS menu bar panel that shows every [herdr](https://herdr.dev) session, its workspaces, and the AI coding agents running in them, with live status. It answers one question at a glance: **which of my agents needs me right now?**

Built and running against a real herd of 16 agents across 4 sessions.

## Install

```sh
brew install sharath-c-s/tap/herdnotch
```

HerdNotch needs macOS 14 or later on Apple silicon. It is not notarized, so the cask removes the download quarantine flag after install; without that step macOS refuses to open it. To build from source instead, see [Building](#building). Maintainers cut a release with `scripts/release.sh <version>`.

## What it does

- **Ledger panel.** One monospaced readout, fixed `SESSION / WORKSPACE / AGENT / KIND` columns, with session and workspace printed only when they change so grouping appears as whitespace. Every column is measured from the values actually on screen at the chosen type size, so the panel is as wide as its content and no wider. The real herd of 16 agents across 4 sessions comes out 441 × 318.5 pt at the smallest type step, 564.5 × 410 pt at the default, and 688 × 491.5 pt at the largest, with no scrolling at any step.
- **Urgency ordering.** Blocked first, then done, then recently completed, then working, then unknown, then idle, with stopped sessions last. Sorted hierarchically so a session is ranked by its most urgent member and the column elision never interleaves. Stable for equal rank, so rows do not reshuffle under the cursor at 1 Hz. `done` is what herdr reports directly; "recently completed" is inferred from `working -> idle` plus a clock, and ranks below it because a guess should not outrank a statement.
- **One hue per state.** Red for blocked, green for done, amber for working, blue for idle, grey for unknown, plus a distinct shape and a weight step for each, so the states stay separable in greyscale and to anyone who cannot tell red from green. Every colour clears 4.5:1 against both the panel surface and the row hover where it is drawn as text, and 3:1 where it is only a mark, and a test asserts it. Note this **deliberately does not match herdr's own palette**, which draws a completed agent in blue: herdr is a closed binary whose config exposes colour values but not the status-to-colour mapping, so the two cannot be reconciled from this side.
- **Status roll-up in the menu bar itself**, so the common case needs no click.
- **Global shortcut and fuzzy search** over every pane, opened by pressing **fn twice**. Subsequence matching with word-start and prefix bonuses, weighted tab label over cwd over agent kind over session name, so `catver` finds `catalog_version_diff`. On an empty query it lists every pane in **flat** urgency order, which is the same ranking the panel applies but resolved across all sessions at once rather than within each workspace, because a flat list has no grouping to explain an interleaved sequence. The shortcut is configurable in the settings window and takes effect without a relaunch.
- **Click to focus** a pane, a workspace, or a session in its terminal.
- **Transient popup** when an agent becomes blocked or finishes, coalescing when several land at once.
- **Detached sessions are marked.** A herdr session can be running, with agents working, while no terminal is attached to it. Those are labelled `no terminal` on a line of their own under the session name, and do not pretend a switch is possible. On its own line rather than beside the name because beside it the marker was measured into the `SESSION` column, and one detached session then set that column's width for every row in the panel.
- **Remote sessions**, through a socket forwarded with `ssh -L`. Marked `remote`, and never claim a local window can be raised for them.
- **A settings window** covering every preference, reached from the status item's right-click menu.

## Running without herdr

HerdNotch works with or without herdr. Set the source in Settings > Agents > Source: herdr only, local only, or both.

In local mode, HerdNotch reads Claude Code sessions from `~/.claude/sessions`. It reads Codex sessions from running `codex` processes and from `~/.codex/sessions`.

In "both" mode, herdr agents come from herdr. Everything else comes from the local sources.

Jump-to-agent detects the host of a session: an iTerm2 or Terminal tab, a tmux pane, an IntelliJ or VS Code window, or otherwise the app. You can turn this off in Settings. Remote sessions need herdr.

## Usage meters

The notch shows usage meters for Claude, Codex, OpenCode Go, and Antigravity. HerdNotch reads credentials from the Keychain and from the CLI auth files. It only reads them. It never refreshes or writes a credential.

## Now playing

The now-playing card works without Xcode tools. It runs through `/usr/bin/perl` and the vendored mediaremote-adapter. Drag the progress bar to seek. The seek applies when you release.

## Layout

| Path | What |
|---|---|
| `HerdKit/` | The herdr protocol client. Pure Foundation, no UI, 58 tests. Newline-delimited JSON over the per-session Unix domain sockets, session discovery (local and forwarded), snapshot assembly, fuzzy search ranking, and the pure urgency ordering. |
| `BoringHerdBar/` | The app. `LSUIElement` menu bar host, the `HerdPanelUI` library holding the ledger view and palette (25 tests), the `HerdShortcut` library holding the configurable global shortcut (11 tests), search, popup, settings window, focus service, and terminal window locator. |
| `karabiner/` | The Karabiner-Elements rule that turns a double tap of `fn` into `F19`, plus an idempotent installer for it. |
| `docs/herd/` | `FEATURES.md`, `PLAN.md`, `DESIGN.md`. Written as a record of what was decided and, more usefully, what was tried and abandoned. |

## Building

No Xcode required, which is deliberate: only Command Line Tools are needed.

```sh
cd BoringHerdBar
./build.sh          # swift build, assemble the .app, ad-hoc codesign
open BoringHerdBar.app
```

Tests need explicit framework flags, because XCTest ships only with Xcode and the suite uses swift-testing:

```sh
cd HerdKit
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $FW -Xswiftc -Xfrontend \
           -Xswiftc -disable-cross-import-overlay-search -Xlinker -rpath -Xlinker $FW
```

Plain `swift test` exits 0 having silently run nothing, because SwiftPM's generated runner guards its entry point behind `#if canImport(Testing)` and per-target settings never reach that generated target. The flags must be on the command line.

The `BoringHerdBar` package has tests too, and they need the same flags:

```sh
cd BoringHerdBar
swift test -Xswiftc -F -Xswiftc $FW -Xswiftc -Xfrontend \
           -Xswiftc -disable-cross-import-overlay-search -Xlinker -rpath -Xlinker $FW
```

Two other traps worth knowing: adding a file to `HerdKit` does not invalidate `BoringHerdBar/.build/release.yaml`, so delete the stale build plan or the app compiles against the old file set; and `NSAppleEventsUsageDescription` must be present in the bundle, because without it macOS *terminates* the process on its first Apple event rather than prompting.

## The fn double-press shortcut

The default shortcut is **fn fn**, a double tap of the globe key. It is not a Carbon shortcut and cannot be: `RegisterEventHotKey` takes a virtual key code plus a modifier mask, and `fn` is neither. It is not in Carbon's modifier vocabulary, and the raw `fn` key arrives as a `flagsChanged` event the hot-key mechanism never sees. The only in-process way to observe it is a `CGEventTap` on `flagsChanged`, which needs the Input Monitoring TCC permission.

So the app registers **`F19`** and a Karabiner-Elements rule turns a double tap of `fn` into `F19`. `F19` is a deliberate choice: no Apple keyboard has that key, so nothing on this machine can generate it and nothing else is listening for it. The app stays dependency-free and needs no extra permission, because it never learns that `fn` was involved.

Install the rule:

```sh
./karabiner/install-fn-rule.sh            # append or update
./karabiner/install-fn-rule.sh --dry-run  # show what would change
./karabiner/install-fn-rule.sh --remove   # take it out again
```

It backs `~/.config/karabiner/karabiner.json` up first, **appends** rather than replacing so existing complex modifications survive, and matches the rule by its `description`, so running it twice leaves one copy. Karabiner reloads within about a second; no restart.

**You may also need to stop macOS acting on the fn tap itself.** The rule forwards `fn` through, deliberately, so `fn`+arrow, `fn`+delete and `fn`+`F1` keep working. macOS's globe-key action fires on that forwarded tap, and Karabiner does not suppress it. So if the emoji picker (or input-source switcher, or dictation) opens as well, set **System Settings > Keyboard > "Press the globe key to" > "Do Nothing"**, or:

```sh
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

then log out and back in. Try it first: whether Karabiner's virtual keyboard triggers the globe action at all was not verified here, because it needs a physical key press.

Any other shortcut is settable in the settings window: click the field, press a combination. It takes effect immediately, Delete resets to `fn fn`, and a combination another application already owns is reported inline instead of silently doing nothing.

## Remote herdr sessions

`herdr --remote <ssh-target>` is an **attach** mechanism, not a session type. It bridges a local client's stdin and stdout over SSH to a herdr server on the far host, so that session's socket lives on that host and no local scan will ever find it.

What does work is forwarding the socket. `ssh -L` can forward a Unix domain socket to a local path, and once one exists every call in this app works against it unchanged:

```sh
# One remote session, forwarded to a local path.
ssh -N -L /tmp/herd-remote/prod.sock:/home/you/.config/herdr/herdr.sock you@prod-host

# A named remote session.
ssh -N -L /tmp/herd-remote/prod_api.sock:/home/you/.config/herdr/sessions/api/herdr.sock you@prod-host
```

Then turn on **Scan extra socket paths** in the settings window and list either the sockets or the directory holding them, one per line. A directory picks up every `*.sock` directly inside it, so forwarding several into `/tmp/herd-remote` and listing that one path is enough.

A remote session is named after its socket path (`prod_api.sock` becomes `prod_api`; a bare `herdr.sock` takes its parent directory's name), is marked **`remote`** in the panel, and never raises a local terminal, because the window hosting it is on another machine. A forward that is down shows as `remote  not reachable` rather than disappearing, and it fails fast: a missing or refused socket costs nothing, and a socket that accepts and then goes silent is bounded by a tighter call budget than a local session gets. Sessions are populated concurrently, so one unreachable remote costs one timeout rather than delaying every local row behind it.

Keep the local path short. `sockaddr_un.sun_path` holds 104 bytes, and `$TMPDIR` on macOS is most of that on its own.

## Two things that will bite you

**No animations.** Any animation in flight over the popover keeps `GraphHost.flushTransactions` running on every pass of the run loop, so the process never sleeps. Measured 19% of a core with an animation present, 0.3% without, and a *finite* animation retriggered from the poll tick still cost 18%. It is not the `repeatForever`, it is having any animation over a backdrop AppKit recomposites per frame. Idle CPU with the panel open is 0.30–0.53% of one core over 75 to 80 seconds with four local sessions at 1 Hz (0.17% with the panel closed, where the poll backs off to 5 s), and 1.05% with two forwarded remotes added on top (six sessions, one of them proxied). Keep it there.

**Notifications cannot be authorized for an ad-hoc signed bundle.** `UNUserNotificationCenter` returns `UNErrorDomain Code=1`. The code path is exercised but no banner can appear, so the transient popup is the only working alert surface. A Developer ID signature fixes it.

## Earlier boringNotch integration

An earlier plan integrated this as a third tab inside [boringNotch](https://github.com/TheBoredTeam/boring.notch). That work never compiled and was removed from the tree, because it carried GPL-3 boringNotch code. It remains in git history before the commit that removed `attic/`.

Notable from that effort: the boringNotch app is sandboxed, so it cannot read `~/.config/herdr/**` at all, and a subprocess inherits the sandbox. The standalone app has no such problem.

## Status

Working and in daily use. Known follow-ups are recorded at the end of `docs/herd/PLAN.md`, including VoiceOver gaps and the terminal window match using `contains` where it should be exact.

Two earlier follow-ups are closed. herdr's `done` state is now a first-class `AgentStatus` rather than folding to `unknown`. **Dynamic Type is closed as superseded rather than built**: the ledger's column widths are measured by CoreText at an exact point size *before* layout, so the size has to be a number the code holds rather than a multiplier resolved inside a view body, and macOS ships no Dynamic Type control comparable to iOS's for that multiplier to come from. The settings window's five-step text size control is the tunable this actually needed, and it moves the whole scale together, including the row height, the gutter and the sigil diameters, which per-`Text` text styles could not. The full reasoning is in `HerdLedgerScale`'s doc comment in `BoringHerdBar/Sources/HerdPanelUI/HerdLedgerColumns.swift`.
