# HerdNotch Open Panel — Bento Redesign Spec (authoritative)

Replaces the dense ledger. Sleek dark cards, 2D bento (not a vertical stack). Agents = hero. SF Pro-forward type. DO NOT touch the reveal mask/animator or NotchCore/NotchGeometry logic.

## Panel
- **720 x 344 pt**, centered under notch, top edge flush y=0. Fits 13.6" Air.
- Panel ground: vertical gradient #000000 (top) → #0B0B0D (bottom), painted as a SwiftUI background inside the existing panel (ground is darker than surface, must recede).
- Card radius 16, inner padding 14 (hero 16), gutter 12, outer pad 16.
- Set `NotchWindowController.expandedSize` → 720x344. Replace ALL 760/480-derived content constants (old NotchContentView body-calc ~:102 + region frames ~:298) with the frames below.

## Notch dead zone
- 200 x 36 centered top; nothing interactive/textual there; painted black. Use the REAL notch rect (NotchGeometry already derives the cutout; controller converts ~NotchWindowController:501) published via `NotchDisplayViewModel` in SwiftUI top-left coords; fall back to 200x36 only for `.pill`/missing geometry.

## Bento frames (pt, origin top-left of panel)
| Element | x | y | w | h |
|---|---|---|---|---|
| Utility band (full width, flanks dead zone) | 0 | 0 | 720 | 44 |
| Agents hero card | 16 | 44 | 424 | 284 |
| Now-playing card | 452 | 44 | 252 | 128 |
| Reminders card | 452 | 184 | 252 | 144 |
Utility band: left flank (16,0,244,36) clock SF Pro 13 semibold textPrimary + date 13 regular textSecondary, x16 baseline-centered; right flank (460,0,244,36) caffeinate toggle + settings gear 28x28 hit targets SF Symbols 13 textSecondary hoverFill circle, 8pt apart, right-aligned ending x684. 1px hairline full width at y44; 8pt gap band→cards.

## Card visual system
- Card fill = **new `cardFill` token** = HerdPalette.surface + white 5% overlay (net ~#17171A), opaque precomposited, for BOTH dark+light palette initializers; keep Sendable. Flat fill, no inner gradient.
- Card edge: 1pt hairline (white7%) inside radius + 1px inner top highlight (white6%, top edge only) = light-from-above.
- Elevation = contrast + hairline, NOT shadow. DROP asymmetric corners / notch flares / panel drop-shadow (they'd need a risky mask refactor — deferred). Keep the existing uniform-cornerRadius mask + reveal untouched.
- Card hover: hairline → white12% 120ms (no scale/translate/fill change). Row hover: HerdPalette.hoverFill.
- Color discipline: chrome = surface/cardFill/hairline/hoverFill + 3 text tiers only. Status color ONLY as: agent dots(+glow), header dot-counts, completed-reminder check + caret (done green #6BD98A), overdue due-labels (blocked red #FF6B6B), collapsed blocked badge. Album art is the only other chroma. working #F2A65A + idle #5E8CB8 NEVER color text (mark-only, fail contrast); use as dots only. blocked #FF6B6B / done #6BD98A are OK as text on dark surface.

## Agents hero card (424x284)
Header (h18): `AGENTS` SF Pro 11 Semibold +0.8 tracking uppercase textSecondary; right-aligned status summary = dot+count pairs `●2 ●1 ●3` (6pt dot in status color + NEUTRAL count SF Pro 11 Medium textSecondary; nonzero only, blocked leftmost). Also show/keep TOTAL live count available (snapshot.counts.total or running sessions).
Rows: up to 5, each 36pt, full width, single inline breadcrumb, 10pt gap after header:
1. Status dot 9pt circle status-color, 2pt inner white15% highlight (lit LED), vcentered, 12pt gap.
2. Session slug in a CHIP: white5% fill, radius5, 5pt h / 2pt v pad, SF Mono 11 Medium textSecondary (first 8 chars of session.name, no ellipsis).
3. ` · ` SF Pro 12 textTertiary.
4. Workspace SF Pro 12 Regular textSecondary, middle-truncate @16 chars (last path component; value = workspace.label ?? workspaceId).
5. ` · ` again.
6. Agent name SF Pro 13 MEDIUM textPrimary (the row anchor; value = agent.displayIdentifier = tabLabel ?? cwd basename).
7. Kind ` (claude)` SF Pro 11 Regular textTertiary (value = agent.agent; omit if == name).
8. Row hover: chevron.right SF Symbol 10pt textTertiary at right edge.
Trailing (right): relative age SF Pro 11 textTertiary (2m/1h), static, computed on publish/open (no timer).
Truncation priority: workspace shrinks first (middle ellipsis), then session tail, agent name never below 12 chars.
**Selection (top 3-5)** — recency is LOCALLY observed (no upstream timestamp; see model step): (1) all blocked, newest local status-change first, always surface; (2) working by local recency; (3) idle by local recency; (4) done only if locally observed <15min. Take first 5; fewer than 5 → show what exists, never pad. Do NOT use HerdUrgencyOrder (it ranks done above working). Empty-map first snapshot → deterministic tree order within buckets.
Footer (h16, bottom, centered): `+ N more · fn fn to search` SF Pro 11 Medium textTertiary, `fn fn` in SF Mono 10 chip (white5% radius5). Only when herd > 5; when ≤5 still show `fn fn to search` at 60% opacity. Click opens fn-fn search window + closes panel.
Empty state: card stays; centered moon.zzz 22pt textTertiary + `The herd is quiet` SF Pro 13 Medium textSecondary + `No active agents · fn fn to search all` SF Pro 11 textTertiary; header keeps no dot-counts.
Row interaction: hover paints hoverFill full row radius8 (120ms in / instant out). Click → agent-selection callback → HerdFocusService.focus(...) → collapse panel.

## Now-playing card (252x128, padding 14) — no header label (art is the header)
.track: art 56x56 radius10 + hairline ring white8%, top-left. Right (10pt gap): title SF Pro 13 Semibold textPrimary 1 line tail-truncate NEVER marquee; artist SF Pro 11 Regular textSecondary 1 line; 6pt below, transport inline left-aligned under title: backward.fill 12pt / play.fill|pause.fill 16pt / forward.fill 12pt, textPrimary, 28x28 targets, 4pt apart. Row2 (8pt below art): scrub full inner width, track 3pt white12% radius1.5, fill white45%, 9pt white knob only on hover/drag, timecodes SF Pro 10 monospacedDigit textTertiary (elapsed left, duration right). Position updates on service poll tick + user scrub only; no interpolation/TimelineView. Paused: only glyph swaps to play.fill.
.runningNoTrack: art slot = white5% rounded square + music.note 20pt textTertiary; title `Nothing playing` 13 Medium textSecondary; artist `Spotify is idle` 11 textTertiary; transport 35% opacity disabled; scrub hidden (row1 vcenters).
.notRunning: centered stack music.note.list 20pt textTertiary + `Spotify isn't running` SF Pro 12 textSecondary + capsule button `Open Spotify` (SF Pro 11 Medium textPrimary, white8% fill, capsule, 22pt tall, 10pt h pad; hover white12%) → openSpotify().

## Reminders card (252x144, padding 14)
Header (h16): `REMINDERS` SF Pro 11 Semibold +0.8 uppercase textSecondary; right overflow count `+2` SF Pro 11 Medium textTertiary.
Rows: max 3, 26pt each, 8pt below header: 14pt hollow circle (1.5pt white25% ring), 10pt gap, title SF Pro 12 Regular textPrimary 1 line tail-truncate, right due chip SF Pro 10 Medium (future textTertiary `2pm`/`Mon`/`Sep 4`; overdue blocked red #FF6B6B). Sort overdue → due date → no-date by creation.
Complete: click circle → fills done #6BD98A + white check + title strikethrough 50%, then 400ms delay, row fades 180ms, reflow (finite once).
Quick-add: permanent last row (h18): `＋ Add reminder` SF Pro 12 textTertiary; hover → textSecondary + hoverFill; click swaps to inline borderless field (12pt textPrimary, placeholder `New reminder`, caret done-green), SET @FocusState on the inserted field; Return commits via RemindersService.add; Esc/focus-loss cancels.
Auth states (replace item area, header stays): .notDetermined → `Herd needs access to Reminders` 12 textSecondary + capsule `Grant Access`; .denied/.restricted → `Reminders access is off` 12 textSecondary + `Open Settings…` 11 Medium textTertiary underline-hover. Empty-authorized → checkmark.circle 18pt done 80% + `All clear` 12 textSecondary; quick-add remains.

## Type scale (complete, authoritative)
SF Pro Display 15 Semibold monospacedDigit (clock); SF Pro Text 13 Semibold (track title); 13 Medium (agent name, empty-heads); 12 Regular (workspace, reminder titles, secondary body); 11 Semibold +0.8 tracking uppercase (card headers AGENTS/REMINDERS); 11 Medium (counts, buttons, footer); 11 Regular (artist, kind, hints); 10 Regular monospacedDigit (timecodes); 10 Medium (due chips); SF Mono 11 Medium (session slugs); SF Mono 10 (fn fn key chip). Line limit 1 everywhere; long titles truncate + `.help()` tooltip.

## Motion (finite, one-shot, interruptible; nothing loops)
Reveal: existing CALayer mask ~260ms easeOut (untouched); cards fade 0→1 + rise 8pt, 180ms each staggered 30ms (hero→now-playing→reminders); band fades with hero — one group, once. Dismiss: mask 200ms + content fade 120ms. Hover: 120ms opacity only. State changes/track/reorder/complete: crossfade 150ms; art swaps crossfade never slide. BANNED: TimelineView, repeatForever, marquee, progress interpolation. Ages/scrub/dots update on discrete model callbacks only.

## Collapsed peek (notch flanks, static, update on model change only, instant swap)
Left flank (blocked>0): capsule white8% 16pt tall = 6pt blocked-red dot + count SF Pro 11 Semibold monospacedDigit textPrimary. Zero blocked = empty.
Right flank (.track only): album art 16x16 radius4 hairline ring white10%; paused 55% opacity. .runningNoTrack/.notRunning = nothing. No text/EQ.

## Model recency (NotchHerdModel) — implement first
No upstream timestamp exists (HerdAgent has none). Keep a local map keyed by (session.name, agent.displayIdentifier) → Date first-seen-in-CURRENT-status; on each publish, if a key's status changed, reset its date to now. Expose: the top-5 shortlist (sort above), a relative-age string per shown agent, and the total live count. Keep the existing published snapshot for BoringHerdBar-shared paths. No perpetual timer.

## Confirmed-available APIs (use directly)
- Total agents `snapshot.counts.total`; running sessions `snapshot.sessions.filter(\.running).count`. NotchHerdModel publishes snapshot + counts.
- Breadcrumb: session.name / (workspace.label ?? workspaceId) / agent.displayIdentifier / kind agent.agent.
- Click-to-key present (NotchPanel.canBecomeKey=true + local mouse-down monitor makeKey() at NotchCommandExecutor ~:272); ALSO set @FocusState on the inserted quick-add field.
- HerdFocusService already constructed in main.swift ~:50 — inject a selection callback to it.
