# HerdNotch

HerdNotch turns the notch on your Mac into a small control room for your AI coding agents. If you run several Claude Code or Codex sessions at once, you know the problem: one of them finished ten minutes ago, another one is stuck on a permission prompt, and you only find out when you go looking. HerdNotch answers one question without a click: which of my agents needs me right now?

It works with [herdr](https://herdr.dev), the terminal workspace manager for agents, and it also works without it. It reads your local Claude Code and Codex sessions directly.

## Install

```sh
brew install sharath-c-s/tap/herdnotch
```

You need macOS 14 or later on Apple silicon. HerdNotch is not notarized yet, so the cask removes the download quarantine flag for you; without that step macOS refuses to open the app. To update later, run `brew upgrade --cask herdnotch`.

## What you see

When the notch is closed, it grows two small wings. They show the one thing that matters most at that moment. An agent that waits for your input comes first, with a waving hand and a count. If nothing needs you and music plays, you see the app that plays it with a small equalizer, and the song title slides in for a few seconds when the track changes. Otherwise you see how many agents are busy, and when nothing at all is happening, your battery level. A small cup on the left wing tells you whether keep-awake is on, and why: steam for a manual hold, sparkles when busy agents hold it, and a moon when lid-closed mode is armed.

When an agent finishes or starts waiting for you, a short toast drops from the notch and the edges of the screen glow in that agent's colour, so you notice it even when you look at another window.

Move the pointer onto the notch and it opens. The Herd page lists every agent with its status, ordered by urgency, next to your plan usage for Claude, Codex, OpenCode Go and Antigravity. The System page holds now playing with a seek bar, your Reminders, battery and power details, and the keep-awake controls. A shelf at the bottom keeps files you drag onto the notch until you drag them out again.

Agents carry the name you gave the session. If you renamed a Claude session with `/rename`, HerdNotch uses that name; otherwise it uses Claude's own title, then the herdr tab name, then the folder. Click an agent to jump to it: HerdNotch finds the iTerm2 or Terminal tab, the tmux pane, or the IDE window that runs it.

## With or without herdr

In Settings > Agents > Source you choose herdr only, local only, or both. In local mode HerdNotch reads Claude Code sessions from `~/.claude/sessions` and Codex sessions from `~/.codex/sessions` and the running `codex` processes. In "both" mode, agents that run inside herdr come from herdr and everything else comes from the local sources, without duplicates.

herdr sessions on another machine work too, if you forward their socket with `ssh -L` and list the local socket path under "Scan extra socket paths" in Settings. Those sessions are marked `remote`, and HerdNotch never tries to raise a local window for them.

## Keep awake

Keep-awake stops your Mac from going to sleep while you want it awake. You can turn it on by hand, with an optional timer, or let rules do it: while agents are busy, while certain apps run, on the charger, or with an external display. Lid-closed mode goes one step further and keeps the Mac awake with the lid shut. That needs a one-time setup in Settings, because macOS only allows it through `pmset`, which needs administrator rights.

## Your credentials

The usage meters read your credentials from the Keychain and from the CLI auth files. HerdNotch only reads them. It never refreshes, rewrites or sends a credential anywhere except to the provider's own usage endpoint, so it cannot log you out of your CLI tools.

## The search shortcut

Press **fn** twice to open search over every agent. Type a few letters (`catver` finds `catalog_version_diff`) and press Return to jump there. macOS cannot register `fn` as a normal shortcut, so HerdNotch listens for `F19` and a small Karabiner-Elements rule turns a double tap of `fn` into `F19`. Install the rule with:

```sh
./karabiner/install-fn-rule.sh
```

The script backs up your Karabiner config first and adds the rule next to your existing ones. If the emoji picker also opens on the tap, set System Settings > Keyboard > "Press the globe key to" > "Do Nothing". You can also pick any other shortcut in Settings.

## Building from source

You need Xcode 26 or later. The tests use Swift Testing and the views use SwiftUI macros, and both need a full Xcode, not only the Command Line Tools.

```sh
cd HerdNotch
DEVELOPER_DIR=/Applications/Xcode.app bash build-notch.sh   # builds, assembles and signs HerdNotch.app
open HerdNotch.app

swift test                    # app tests
(cd ../HerdKit && swift test) # herdr client and agent sources
```

The repo has two Swift packages. `HerdKit` talks to herdr and reads the local agent sources; it has no UI. `HerdNotch` is the app: the notch, its pages, the keep-awake and usage services, and the pure decision logic in `NotchCore`, which carries most of the tests. Releases are cut with `scripts/release.sh <version>` from a clean `main`.

## Known limits

HerdNotch is ad-hoc signed, so macOS does not let it post system notifications; the toast and the screen glow are its alerts instead. A Developer ID signature would fix that and would also let macOS remember its permissions across updates.

## Credits

The usage meters follow the approach of [OpenUsage](https://github.com/robinebers/openusage) (MIT). Now playing uses the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause). Some features were inspired by Vorssaint; no code was copied. See `NOTICE.md` for details. HerdNotch itself is MIT licensed.
