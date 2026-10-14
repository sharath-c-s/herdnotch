# Feasibility spike: Ice/Bartender-style menu-bar overflow management for HerdNotch

Phase 8 idea under evaluation: hide *other apps'* menu-bar icons and surface them from the notch, the
way Ice (jordanbaird/Ice) and Bartender do. This is a spike, not a design doc. It answers one
question: is this worth building, on macOS 26.2, for an unsandboxed, ad-hoc-signed, `LSUIElement`
app with no special entitlements.

**Verdict: not worth it as a "hide other apps' icons" feature. Feasible only with a fragile,
permission-heavy, OS-version-chasing implementation that is disproportionate to HerdNotch's scope.
A much smaller, genuinely useful slice (HerdNotch managing its own status item) is already free and
already close to what `HerdStatusItem` does today.**

## Environment checked

- macOS 26.2 (build 25C56), confirmed via `sw_vers`.
- `HerdNotch.app` is ad-hoc signed, hardened runtime on, `TeamIdentifier=not set`, no
  `com.apple.security.app-sandbox` entitlement (confirmed via `codesign -dv --entitlements :-`). Its
  only entitlement is `com.apple.security.automation.apple-events`, for Apple Events to Spotify.
  So: genuinely unsandboxed, as the plan assumed.
- `LSUIElement = true` in `Info.plist`, no Accessibility usage description or entitlement present.

## What the known techniques actually require, and what still works

### (a) Create your own oversized/negative-length `NSStatusItem` to push or cover neighbors
**Works, trivially, no permission needed.** Probed directly: `NSStatusBar.system.statusItem(withLength: -1)`
creates and installs an item with no Accessibility trust, no entitlement, nothing beyond normal
AppKit. This is the mechanism behind the classic "spacer" trick, and it is exactly as available on
26.2 as it always was. `HerdStatusItem` already creates/sizes/removes its own item this way.

### (b) Move or hide the app's own status items
**Works, trivially, no permission needed**, and is simpler than the literature suggests: you don't
even need to move an item off-screen, `NSStatusItem.isVisible = false` (or removing it, as
`HerdStatusItem.remove()` already does) hides your own item outright. This applies only to items
*you* created.

### (c) Read other apps' menu-bar item positions/identities via the Accessibility API
**Confirmed blocked without the user granting Accessibility permission, no way around it.** Probe
results (unsigned Swift script, run from this Terminal session, which is not currently
Accessibility-trusted):

```
AXIsProcessTrusted() = false
...
AX read of SystemUIServer AXMenuBar -> error=-25211 (kAXErrorAPIDisabled)
```

`kAXErrorAPIDisabled` is the exact error AppKit returns for any cross-process AX call when the
calling process is not trusted. This is not a bug or a workaround-able state, it is the permission
gate working as designed, on 26.2 same as every macOS release since accessibility trust existed.
There is no code path in (c) that avoids asking the user for Accessibility access in System
Settings, and it must be *this specific app's* binary that gets approved (ad-hoc signing makes this
worse in practice, since an unnotarized/ad-hoc binary's TCC grant can be invalidated by rebuilds,
which is a known pain point for local Ice/Bartender-style dev builds).

A second finding narrows this further: on 26.2, the public (unentitled) `CGWindowListCopyWindowInfo`
enumeration, which never needed Accessibility trust, now attributes a large share of third-party
menu-bar-item windows to **owner `"Control Centre"`** with generic names like `Item-0`, rather than
to the owning app:

```
layer=25 owner=Control Centre name=Item-0 bounds=[...]
layer=25 owner=Control Centre name=Item-0 bounds=[...]
layer=25 owner=Control Centre name=extension_obsidian_obsidianMenuBar__... bounds=[...]
```

So even the free, permission-less window list no longer reliably tells you *which app* owns a given
icon at a given position, only that *something* is there, hosted through Control Center's compositor.
Reliable identification of "this icon belongs to Slack" requires exactly the AX tree that (c) shows
is gated behind Accessibility trust. This is a real regression in feasibility versus the older macOS
versions Ice's original design targeted, and is consistent with Ice's own GitHub issues reporting
breakage on recent macOS releases.

### (d) System "auto-hide menu bar" + an expanding control item
This is a real, unrelated macOS feature (System Settings -> Control Center -> "Automatically hide and
show the menu bar"). It hides/shows the *entire* bar based on mouse position, not per-item, and a
third-party app has no hook into it beyond `NSApp.presentationOptions`. It does not give a way to
selectively surface only the overflowed icons in the notch, so it does not serve the actual feature
goal and isn't a building block for it.

## What's NOT covered by the probe, and why

The probe deliberately stopped at *reading* other processes' state. It did not attempt to actually
*move* another app's status item, because:

1. Doing so meaningfully requires Accessibility trust granted to this exact ad-hoc binary, which
   means walking through System Settings and approving it, an action with real, persistent
   consequences on this machine (a live desktop) that a bounded, unattended spike should not take
   without being asked to.
2. Every public writeup of how Ice/Bartender actually reposition someone else's icon (there is no
   supported API for this, full stop) describes simulating the user's own "Cmd+drag to rearrange menu
   bar icons" gesture via synthetic `CGEvent`s posted at the target icon's on-screen coordinates. That
   is: fake a Cmd-held mouse-down, drag, mouse-up on top of someone else's icon, and let the window
   server treat it like a real user drag. It has no documented API, it depends on exact pixel
   coordinates read from the very AX tree (c) shows is gated, and it is exactly the kind of thing that
   breaks on major OS updates: Bartender needed a rewrite for Big Sur, and Ice's issue tracker has
   several "broken on macOS 15/Sequoia" reports about this same mechanism. Rehearsing it against a
   real, in-use desktop menu bar (this machine's) as part of an unattended probe is not a safe or
   proportionate test, so it wasn't attempted.

## Recommendation

**Drop "hide other apps' menu-bar icons" as a HerdNotch feature.** The mechanism that would make it
work is: (1) gated behind an Accessibility permission grant that most users are rightly cautious
about, (2) built on a synthetic-input trick with no supported API, that has to be rebuilt every couple
of major macOS releases (per Ice's and Bartender's own histories), and (3) on 26.2 specifically, even
the free identification step (which app owns which icon) is degraded because Control Center now
fronts many third-party items in the public window list. That is a multi-week, ongoing-maintenance
feature for a personal utility, not a bounded addition.

**What's genuinely free and already half-built:** HerdNotch/BoringHerdBar can fully manage the
visibility, size, and content of **its own** status item(s), no permission, no private API, nothing
fragile. `Sources/BoringHerdBar/HerdStatusItem.swift` already does exactly this (creates, resizes,
and can remove its own `NSStatusItem`). If the underlying itch is "the menu bar feels crowded",
the honest lazy version is: give HerdNotch's own status item a user preference to hide itself when
not needed (it can already be removed via `remove()`), not attempt to manage everyone else's icons.
That is not being proposed here as new work, just noted as the ceiling of what's actually available
without the Accessibility ask.

## Effort estimate (if someone insisted on building it anyway)

- Read-only enumeration + identification of other apps' items via AX (needs Accessibility grant, TCC
  UX, ad-hoc signing re-grant friction): ~3-5 days for a first working version.
- Actual hide/show via simulated Cmd-drag CGEvents, coordinate math, retry/verification logic for when
  the drag doesn't land: ~1-2 weeks, fragile.
- Ongoing: re-validation and likely fixes on every macOS major release, indefinitely, per Ice's and
  Bartender's track record.

## Probe artifacts

A throwaway Swift script (`ice_probe.swift`) was written to a scratch directory outside this repo,
run once via `swift ice_probe.swift`, and not committed. It performed only read-only checks:
`AXIsProcessTrusted()`, `CGWindowListCopyWindowInfo`, and `AXUIElementCopyAttributeValue` against this
process and `SystemUIServer`, plus creating and immediately removing one throwaway `NSStatusItem` to
confirm (a)/(b). No other app's window or menu-bar item was touched, moved, or queried successfully
(the SystemUIServer read failed with `kAXErrorAPIDisabled`, as reported above). Nothing in NotchCore,
NotchGeometry, the mask animator, or any shipped feature was touched.
