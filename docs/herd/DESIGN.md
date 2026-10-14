# boring-herd — visual direction

Applies to `BoringHerdBar`'s popover and, later, to the fork's Herd tab. Dark mode is the primary and default target; light mode must remain legible but is not where the design is tuned.

## Thesis

**This is an instrument panel, not a list.** Its single job is to answer one question at a glance: *which of my agents needs me right now?* On a normal day 14 of 16 agents are idle and the correct answer is "none". A design that renders all 16 with equal weight forces the user to read every line to learn nothing, which is the failure mode the current build has.

So the governing rule is: **attention is a budget spent only on exceptions.** The panel should be almost silent when everything is fine and unmistakable when something is blocked.

**The shape that carries this is a ledger, and it replaced an indented list.** Three directions were built and captured against the real herd before choosing: a summary-first *Marquee* that stated the answer in one large line and compressed the idle agents into per-session tick strips, a *Board* of fixed cells learned by position, and this one. The list the panel started as was neither chosen nor rejected on its merits; it was simply the default, and it was the thing all three were measured against. The ledger won because it answers "which agent needs me" in a single vertical scan of one 13 pt gutter, with no text read at all, and because its all-idle state is *perfectly uniform*, which makes uniformity itself the answer on the fourteen-of-sixteen day. It also fits sixteen agents in 309 pt against a 420 pt cap, so the scroll the user complained about is gone rather than merely shortened.

The thesis did not change. Only the geometry did: hierarchy moved from indentation to columns, and status moved from a dot beside a label to a sigil in a gutter.

The vernacular to borrow from is the subject's own world: terminals, process monitors, tmux status lines. Not app chrome. But borrow the discipline, not the costume: no ASCII cosplay, no fake CRT.

## The risk worth taking

**Idle rows are de-emphasised, but the first two drafts of this section got the amount wrong twice, in the same direction.** The instinct is right and the execution kept overshooting, so the rule is now stated as a floor rather than as an instruction to dim.

**The rule: idle is recessive, never strained to read.** Concretely, and this is not negotiable by eye:

- **Every text token clears 4.5:1** against the background it actually sits on, including the hover fill and the search selection, not just against the bare surface. Every font here is 12 pt or smaller, so the large-text exemption never applies.
- **Every non-text indicator clears 3:1.** That covers the status dots and the selection marks.
- Hierarchy is carried by **the distance up to `textPrimary`**, not by pushing idle down towards the surface. If idle and blocked do not feel far enough apart, make blocked louder or primary brighter. Never lower the floor.

What this replaced, and why, so nobody re-derives it: idle identifiers were at 4.51:1, which is on the line; the agent-kind tag was drawn in `hairline` at **1.28:1**, which meant the `CLAUDE` and `CODEX` tags were invisible on the fourteen rows out of sixteen where they appeared; the idle rings were also `hairline` at 1.28:1, so the mark whose entire job is to confirm an agent is alive could not be seen; and metadata was at 3.05:1. Four separate elements had been dimmed past the point of doing their job. The user reported the panel as too dim twice before this was fixed.

Note also that **dimming idle never bought any space.** Row height is set by text, not by the dot, so an idle row costs exactly what any other row costs. De-emphasis was only ever buying attention, so it should only ever have been spent to the point where attention is redirected, not to the point of illegibility.

The two surfaces still differ in register:

- The **status item** is always on screen and was never asked for. It must be quiet, and near-silence there is correct.
- The **popover** is opened deliberately. A panel that is unreadable on an all-idle day fails the user, because "everything is fine" is an answer they came for and are entitled to read comfortably.

**Search** relaxes further. A result row is something the user asked for by name, so it is not competing with fifteen rows they did not ask about.

## Colour

Two saturated colours in the entire interface. That constraint is the design.

**The surface is opaque, and this is the correction that mattered most.** The first two drafts specified `surface` at about 85 % over the popover's vibrancy material, on the reasoning that letting the desktop through is more alive and more macOS. In production the token was not applied at all, so the panel was whatever the system material gave it, and the user's terminal text read straight through the rows. Both the value and the reasoning were wrong. Vibrancy earns its keep over a photograph and costs you everything over dense monospace text, and this panel is only ever summoned in front of the latter. It is also what dragged the worst-case contrast ratios down to 2.86:1 for idle text and 1.94:1 for metadata against a bright window. Opaque, every time. There is nothing to reduce for `accessibilityReduceTransparency` because there is no transparency left.

All three surfaces use the same token: the popover, the search window, and the transient popup. They previously used three different treatments, which is how one of them ended up transparent without anyone deciding it should be.

### Dark, the tuned target

Ratios are WCAG 2.1 against `surface`. Every font in the app is 12 pt or smaller, so **4.5:1 is the bar for all text** and 3:1 for non-text indicators.

| Token | Value | On surface | Use |
|---|---|---|---|
| `surface` | `#16171A` | — | Panel base, opaque. Every other ratio here is measured against it. |
| `hairline` | `#2A2C31` | 1.28 | **Dividers only.** Never text, never an indicator: at 1.28 it cannot carry either. |
| `hoverFill` | `#202226` | — | The composited row hover. A literal value, not `hairline` at an opacity, because the tightest margin in the palette is measured against this exact colour: `textTertiary` sits at 4.63 on it. An opacity would make that number a guess. |
| `textPrimary` | `#E8E9EC` | 14.76 | Identifiers on working rows, and on rows inferred as just finished. Blocked and done identifiers take their own hue. |
| `textSecondary` | `#9AA0A8` | 6.80 | Session and workspace names; the `unknown` ring; the search selection ring. |
| `textIdle` | `#969CA5` | 6.48 | Identifiers on idle rows. Recessive, never strained. |
| `textTertiary` | `#848B94` | 5.21 | Agent kind, counts, search context lines, the search prompt mark. |
| `identifierHover` | `#FFFFFF` | 18.4 | The identifier under the cursor, one step past `textPrimary`. |
| `blocked` | `#FF6B6B` | 6.46 | Blocked rows, **and the app's error register**: banner faults, stand-in lines, settings warnings, the degraded status marker. Drawn as text, so 4.5:1 applies. |
| `done` | `#6BD98A` | 10.17 | Rows herdr reports as finished. Drawn as text, so 4.5:1 applies. |
| `working` | `#F2A65A` | 8.86 | In-progress rows. A mark only, never text, so 3:1 applies. |
| `idle` | `#5E8CB8` | 5.05 | Idle rings. A mark only. Pitched at the loudness of the `textTertiary` grey it replaced. |

### Light, legible rather than tuned

| Token | Value |
|---|---|
| `surface` | `#F2F2F4` |
| `hairline` | `#D6D8DE` |
| `textPrimary` | `#1A1C20` |
| `textSecondary` | `#4A505A` |
| `textIdle` | `#545A64` |
| `textTertiary` | `#5F656E` |
| `identifierHover` | `#000000` |
| `blocked` | `#B4232B` |
| `done` | `#166B35` |
| `working` | `#A85F14` |
| `idle` | `#3A7AAA` |

Every light text token is darker than `#6F6F6F`, which is where 4.5:1 lands against that surface, so the same floor holds in both schemes.

### Four accents, one per state, and the rule this replaced

**Superseded, 2026-08-03.** This section used to say `blocked` is **amber, not red**, on the grounds that red means failure, a blocked agent has not failed but is waiting for you, and amber is the instrumentation vernacular for "attention". It also said the panel holds exactly two saturated colours, that idle draws no colour at all, and **do not add a third accent**.

The user overruled all of it. The specific complaint was that blue-for-working is counter-intuitive when herdr itself draws a *completed* agent in blue, so the two surfaces the user reads side by side taught opposite things with the same hue. The scheme they asked for names each state by its colour rather than requiring the vocabulary to be learned:

| state | hue | glyph |
|---|---|---|
| blocked | red | filled disc, largest, with a glow |
| done | green | checkmark |
| working | amber | filled triangle |
| idle | blue | hollow ring, small |
| unknown | grey (`textSecondary`) | hollow square |

Two parts of the old rule survive on their merits and should not be undone:

- **`unknown` stays colourless.** A hue is a claim about what the agent is doing, and `unknown` is exactly the case where there is no such claim: herdr did not classify the pane, or reported a state this build predates. Grey is honest, and it keeps `unknown` visibly a non-state rather than a fifth thing to learn.
- **Do not reach for a colour to fix a greyscale problem.** The floors are still the floors. `HerdPaletteTests` asserts every token against both the surface and the hover fill, 4.5:1 where it is text and 3:1 where it is a mark, so lowering one to make a hue prettier fails a test.

Two consequences worth knowing before touching these values. `blocked` moving to red **improved** its secondary duty: it is also the colour of banner faults, stand-in lines, settings warnings and the degraded marker, and red suits those better than amber ever did. And `idle` gaining a hue was the risky half, because idle is fourteen rows of sixteen on an ordinary day, so it is the one colour that could drown the other three by count. It is mitigated by staying hollow and small and by being pitched at the loudness of the grey ring it replaced, and `HerdPaletteTests.idleStaysRecessive` pins that as a property rather than as a hex value. That test earned its keep immediately: the first light-mode blue tried, `#2A6E9E` at 4.91:1, cleared its floor but came out louder than `working` and inverted the emphasis order.

Judged on captures of the all-idle fixture in both appearances, which is where a hue on idle would show up worst.

## Type

The content is mostly **code identifiers**, not prose: `loader_error_classification`, `catalog_version_diff`, `w3:tG`. Setting identifiers in a UI sans is a category error and is a large part of why the current build reads generic.

**The panel is set in one face, and that is itself the idea.** A ledger is a readout, and a readout in two typefaces is a form. Everything in the panel is `SF Mono`, and the roles are separated by size and weight alone:

| Role | Setting | Where |
|---|---|---|
| Identifier | `SF Mono` 10.5, regular; **semibold** for `blocked`, `done` and `working` | the agent column |
| Context | `SF Mono` 9 | the session and workspace columns, the kind column, a stopped session's stand-in line |
| Column headings | `SF Mono` 8, medium, uppercase, 0.8 tracking | the one heading row, and the `no terminal` and `remote` marker line |

The weight step is load-bearing rather than decorative. It is the colourless carrier of the three exception states, so a blocked, done or working row still reads as the exception in greyscale, on a laptop screen in a bright room, or to anyone who cannot separate red from green or amber from grey. That last case is not hypothetical now that the palette runs to four hues: red and green together are the commonest confusion there is, which is exactly why they carry different shapes and the same weight step as well. With motion forbidden (see **Motion**) the panel needs every redundant channel it can get, and weight is free.

**Column widths are measured from the values on screen, not declared.** They used to be five constants, each sized by hand for the longest value across every session the user happened to have, and that was wrong the first time the herd changed shape: disabling two sessions through the session filter removed the long values but not the space reserved for them, so the panel stayed 506 pt wide with a `SESSION` column that was almost entirely empty. Nothing recomputed, because there was nothing to recompute.

A monospaced face is what makes measuring cheap enough to do on every snapshot: each column is the widest value it actually holds, so the panel's width is the consequence of its content rather than a round number chosen first. Measured against the real herd of sixteen agents across four sessions, one of them detached and one stopped: **441 × 318.5 pt at the 10.5 pt step, 564.5 × 410 pt at the 13.5 pt default, and 688 × 491.5 pt at the 16.5 pt step**. Nothing scrolls at any step, because the body's cap scales with the type as well: 420, 540 and 660 pt against a body needing 294, 381 and 460.5 pt.

**Session-scoped markers are deliberately outside that measurement, and that is a correction to what this document used to say.** `no terminal` printed beside the session name, inside the `SESSION` cell, so it was part of what the column was measured from, and it was the widest thing that column ever held. At the 13.5 pt default the marker and its gap were 75.5 pt of a 195.5 pt column, and all sixteen rows paid for it in order to say one thing about one session: the panel came out 640 pt wide with roughly 140 pt of dead space between every session name and the workspace beside it. It was the widest content on screen doing the least work. The markers now print on **their own line, indented under the session name**, outside the grid, measured by nothing, at a line height well under a row's so the line reads as an annotation on the name rather than as a row with a missing agent. Position now carries what shared width used to, which is what the **Colour** section asks for anyway: distinguish with weight, space or position, never with a third accent.

The advance now comes from CoreText rather than from a remembered number, and the remembered number was wrong. A previous pass recorded SF Mono at 10.5 pt as advancing 6.45 pt; it really advances **6.4907 pt**, so 27 characters of `loader_error_classification` need 175.25 pt rather than the 174.15 pt the old figure predicts, and that 1.1 pt is exactly why a column declared at 174 pt clipped the single most important row in the panel by one character. Two font-resolution traps are worth recording, because both fail quietly rather than loudly: asking CoreText for `SFMono-Regular` by name returns **Helvetica** (8.75 pt at 10.5 pt, so every column a third too wide), and asking for the `userFixedPitch` UI font returns **Menlo** (6.32 pt, so every column slightly too narrow). The face SwiftUI's `design: .monospaced` actually uses is reached by copying the system UI font with the monospace symbolic trait.

Two rules keep the measurement from becoming a nuisance. Widths only ever **grow while the panel is on screen**, so an agent appearing or finishing at the 1 Hz poll cannot resize the popover under a cursor that is reading it; they are re-measured from scratch the next time the panel opens, which is when a user who has just changed the session filter is looking at it. And every column is clamped between the width of its own heading and a ceiling, so a pathological tab label truncates in its own column instead of pushing the popover past 640 pt.

The other surfaces keep the two-face setting they had, because they are not tables: **chrome** (popup copy, status item) is `SF Pro Text`, and search sets its query and results in `SF Mono` 11 medium for the reason given under **Search**.

## Signature element: the gutter and the elided columns

**There is no rail, and there is no longer a ladder either.** Both were taken off, in that order, and for the same reason each time: each was a second rendering of a hierarchy something else had already stated. The rail restated the indentation. The indentation, it turned out, restated what columns state better.

Two things carry the panel now.

**The gutter.** The leftmost 13 pt of every row holds nothing but a status sigil. Because it is a fixed column at the reading origin, the panel's left edge becomes a barcode: sixteen marks in a vertical line, read in one saccade, before a single word has been read. This is the whole reason the direction was chosen. A dot paired tightly with its label, as the list had it, is legible once you are already reading that row; a dot in a column is legible before you read anything.

**Elided columns.** The session and workspace columns print a value only when it changes, so grouping appears as whitespace exactly the way it does in a printed report. That is what replaced indentation, and it is strictly cheaper: an indented tree spends horizontal space on every row to express containment, whereas elision spends none and expresses it by absence. It also means the identifier column starts on one axis for all sixteen rows, which an indented tree can never manage.

Elision is what forces the **ordering** to be hierarchical rather than flat, and that constraint is worth stating here because it looks like a sorting detail and is actually a typographic one. See **Ordering**.

The panel's sigil vocabulary. Five distinct shapes at four distinct sizes, and the redundancy is deliberate: shape survives greyscale, a bright room, and colour vision deficiency, none of which hue does.

| Status | Rendering | Ratio |
|---|---|---|
| `blocked` | 9 pt filled disc in `blocked` | 6.46 |
| `done` | SF Symbols `checkmark`, 7 pt bold, in `done` | 10.17 |
| just finished (inferred) | SF Symbols `checkmark`, 7 pt bold, in `textPrimary` | 14.76 |
| `working` | 8 x 9 pt filled triangle in `working`, pointing right, static | 8.86 |
| `idle` | 6 pt hollow ring, 1 pt, in `idle` | 5.05 |
| `unknown` | 6 pt hollow square, 1 pt, in `textSecondary` | 6.80 |

**`done` and "just finished" share one shape on purpose.** There is a single glyph in this vocabulary for finished, and the two rows differ only in colour: green is herdr saying so, `textPrimary` is this app inferring it from `working -> idle` plus a clock. A second shape would imply they are different states when they are the same state known two ways.

`working` is a **triangle rather than a disc** so that shape, not only hue, separates it from `blocked`. This was the one place a single-colour ledger was seriously considered and rejected: an earlier draft of this direction spent no colour on `working` at all, carrying it on shape and brightness, on the argument that hue is the first channel to degrade in a bright room. It was dropped because the status item, the transient popup and the search window already draw a working agent in `working`, so a grey ledger would have made this the one surface in the app where the state looked like something else. Consistency across four surfaces beat single-colour purity.

The **search results keep the dot vocabulary below**, which differs from the panel's on purpose. Search rows hang a dot in a 10 pt column beside an identifier rather than in a 13 pt table gutter, and there is no rhythm of identical marks for a shape to break. Both draw from the same palette, so each hue means one thing everywhere.

| Status | Rendering | Ratio |
|---|---|---|
| `blocked` | 9 pt filled disc in `blocked`, with a two-stop glow that spills past its column | 6.46 |
| `done` | 8 pt filled disc in `done`, no glow | 10.17 |
| `working` | 7 pt filled disc in `working`, static | 8.86 |
| `idle` | 6 pt hollow ring, 1 pt, in `idle` | 5.05 |
| `unknown` | 6 pt hollow ring, 1.5 pt, in `textSecondary` | 6.80 |

The glow is **reserved for `blocked` alone**. It is what makes a waiting agent findable in peripheral vision, and a finished agent wants to be found on the next glance rather than to interrupt the current one.

Idle stays recessive by being **hollow and small**, which is the honest way to do it, rather than by being drawn in a colour nobody can see. The earlier specification put the idle ring in `hairline` at 1.28:1, which failed the 3:1 an indicator needs by a wide margin and meant the one mark confirming an agent was alive could not be made out. `unknown` is a step louder than idle, because "I cannot tell" is worth noticing where "nothing is happening" is not. Neither ring uses an accent, so idle still draws no colour.

## Ordering

Rows are ordered by **urgency**, not by name or by discovery order: `blocked`, then `done`, then recently completed, then `working`, then `unknown`, then `idle`, with stopped sessions last. `unknown` sits above `idle` because it is more often a bug than a state, so burying it under fourteen idle rows would hide the one row indicating the panel itself is wrong. `done` sits above the inferred "recently completed" because it is herdr's own statement rather than this app's guess, and it needs no clock to stay true.

**The panel sorts hierarchically and the search window sorts flat, and that is not an inconsistency.** In the ledger, agents are ranked inside their workspace, workspaces inside their session, and each group takes the rank of its most urgent member, so a group stays intact and the elision that prints a session name only when it changes keeps working. The search window has no grouping to explain an interleaved sequence, so it applies the same ranks across every session at once. Preserving the ledger's traversal into the flat list was tried and is wrong: a real six-pane herd came out `working, idle, working, working, idle, idle`, which is correct hierarchically and reads as unsorted once the workspace names are gone. The two surfaces agree about what "sorted" means, not about a byte sequence.

**Recently completed** means a `working -> idle` transition inside the last **90 seconds**. The window is chosen against the surrounding behaviour rather than picked round: the transient popup announcing a completion is on screen for a couple of seconds, so anything much shorter would let the row sink before the user finished reading the popup and reached for the menu bar, and anything much longer turns the top of the panel into a graveyard of things that finished minutes ago, which is the opposite of the panel's job.

**The sort is hierarchical, not flat, and elision is why.** A session is ranked by its most urgent member, a workspace likewise, and agents are ranked inside their own workspace. Sorting sixteen agents into one flat urgency order would interleave sessions, so every row would have to reprint its session and workspace and the elision that makes the panel readable would collapse into noise. Urgency propagates upwards instead; the groups stay intact and reorder whole.

**The sort is stable**, with the element's original position as an explicit tie-break. `Array.sort(by:)` offers no stability guarantee in Swift, and an unstable sort re-run at 1 Hz would let rows of equal rank swap places under the cursor. On the all-idle day *every* comparison is a tie, so this is not an edge case.

A promoted row must **say why it was promoted**. Ordering a recently-finished agent to the top while it still looks exactly like the idle rows beneath it is a movement the user cannot account for, and unexplained movement reads as the panel shuffling at random. Hence the checkmark in the sigil table above, and "just finished" rather than "idle" in the row's VoiceOver label.

Ordering lives in the model layer, not in `HerdSnapshotBuilder`: recency needs a clock and the memory of the previous snapshot, and the builder is deliberately a stateless snapshot builder shared with the fork. The *ranking rule* is a pure function and does live in HerdKit, so the fork gets identical ordering without inheriting a clock. Leaving the builder untouched also keeps its output neutral for search, which ranks by fuzzy score and wants no urgency bias applied first.

## Attachment

**A session can be running, with live agents, and have no terminal attached to it.** Clicking such an agent focuses the pane server-side, every herdr call succeeds, and nothing appears to happen, because there was never a window to bring forward. This was reported as "selecting a tab in a different session does not switch", and it was diagnosed as a window-matching problem for longer than it should have been.

Attachment was believed to be undetectable. `herdr-client.sock` is created by the server rather than by a client, so its presence proves nothing, and that negative control was checked twice. The answer comes from **`client.window_title.set`**, which cannot apply a title without a foreground client and says so, returning `{"changed": false, "reason": "no_foreground_client"}`. One round trip, authoritative.

So the panel marks it. A running session with nothing attached prints **`no terminal`** on its own line under its name, once per session, in `textTertiary` at 5.21:1 rather than in an accent: it is a limitation to know about, not an alarm, and the accents are spent entirely on agent state. The `herdr session attach <name>` remedy sits in that session's tooltip, on the sessions where it is actually true. It used to be a fourth tooltip line on all sixteen agent rows, where it was untrue most of the time and therefore ignored.

It printed *beside* the name until it was measured: sharing the session cell made it part of the shared column geometry, and it was the widest thing in there, so one detached session widened the `SESSION` column for every row in the panel. See **Type** for the numbers. Its own line costs one short line of height per marked session and gives back about 75 pt of width at the default size, which is the right way round for a panel that must not scroll.

Clicking into a detached session still selects the pane inside herdr, which is correct and will be waiting when the user attaches, but it deliberately **does not activate the terminal application**. Raising the terminal would bring forward a window showing some other session, which is the behaviour that made the original bug read as "nothing happened": something did happen, it just was not what was asked for.

**Window titles are stamped and left in place**, as `herdr: <session>`. This is a product decision, not a shortcut. herdr titles every attached window `herdr (herdr)`, so two attached sessions were previously indistinguishable both in the user's own window list and to any code trying to find one of them; a per-session title fixes both with one string. It is idempotent, so re-probing costs nothing visible, and it removes a race: terminals apply titles asynchronously, which is the only reason a window search has to poll at all, and a title that is already present makes the window findable immediately. The probe is a write, so it runs when the panel opens rather than on every poll, which is also exactly when being correct matters.

## Search

A third surface, opened by a global shortcut rather than by the status item, and the only one the user summons by typing. It is a flat ranked list, not a filtered tree: the panel answers "which agent needs me" and answers it with hierarchy, whereas search answers "where is the one I am thinking of", which wants every row equally loud because the user has already said what they want.

Three rules keep it inside this document rather than beside it.

- **The query is set in the identifier face**, SF Mono 11 medium, the same as the result rows beneath it. What the user types is a fragment of an identifier, so setting it in the chrome face would put the thing being matched and the thing it matches against in two different typefaces.
- **Matched characters are lit by moving up the text ramp**, not by introducing a colour. Unmatched characters sit at `textSecondary` for the tab label and `textTertiary` for the path; matched ones step to `textPrimary`. No third accent enters the design, and the highlight doubles as the explanation of why a row is in the list at all.
- **Selection is a ring in `textSecondary` over a `hairline` wash.** A solid `hairline` fill was tried first, on the argument that every row here is a candidate so the mark may be louder than the panel's. It measured 1.28:1 against the surface, which fails the 3:1 an indicator needs, so the mark telling the user which row Return would take was the weakest thing on screen. The ring at 6.80:1 does the signalling; the wash stays subtle so the row's own text keeps the contrast it was measured for. Hover uses the wash alone.

## Motion

**There is no motion. The panel is entirely static, and this was forced by measurement rather than chosen.**

The intent was exactly one animated thing: a working agent's dot breathing on a 2 s ease-in-out opacity cycle. It shipped that way and it hung the app. A repeating SwiftUI animation never completes, so its transaction stays pending, so `GraphHost.flushTransactions` runs on every pass of the run loop and the process never sleeps. Measured with a single working agent in a forty-row popover: **19 % of a core with the panel merely open and nothing happening**, against 0.3 % with the animation removed, and the user saw it reach 99 %.

Three fixes were tried and measured before giving up on motion:

- Retriggering a **finite** animation from the 1 Hz poll tick instead of repeating forever: **18 %**, no better. The cost is not the repeat, it is having any animation in flight.
- Replacing the `LazyVStack` with a plain `VStack`: no change.
- Removing the popover's `preferredContentSize` auto-sizing: no change.

The per-frame cost is AppKit recompositing the popover's backdrop and rebuilding the display list, not our layout, so it is not something this design can tune away. Since fill and colour already separate working from idle unambiguously, motion was the part that could go: `working` is now a filled 7 pt disc, `idle` a hollow 6 pt ring.

If motion is ever wanted back it needs a rendering path outside the SwiftUI view graph, a `CALayer` opacity animation driven from the host. That is possible but it cannot live in the `HerdPanelUI` target, which may not import AppKit. The panel is now its own library target depending on HerdKit alone, which enforces most of that rule mechanically: it cannot see `HerdBarModel`, `HerdPreferences`, the status item or any other host type, so host coupling fails to compile rather than failing review. AppKit itself is a system framework and remains importable by any macOS target, so *that* half stays a rule a human has to keep. The target boundary is what makes it a one-line check instead of a whole-file read.

Everything else was already static and stays so: no row hover animations beyond an instant state change, no list entrance animation, no shimmer. `accessibilityReduceMotion` now has nothing to suppress.

## What to remove

Done, and recorded so nobody puts them back:

- **The green hover band.** It read as a selection error rather than as a hover, and green was never in the palette. Hover is now a `hoverFill` wash plus a brightening of the identifier to `identifierHover`: the row leans forward instead of being struck through with a marker.
- **The right-hand count numerals.** Removed outright rather than aligned into a column. In a ledger the count is redundant, because the rows are one per agent and you can count them.
- **The four-line tooltip.** It covered a third of the panel and its fourth line, the `herdr session attach` advice, was untrue on most rows. Row tooltips are three lines; the advice moved to the session it applies to, on the sessions where it is true.
- **The workspace agent-count column**, for the same reason as the numerals.

Chanel's rule applies at the end. Once it is built, take one thing off. **Four times now this has been the same mistake**, and the pattern is worth naming because every instance was defended as structure and every instance was redundancy: the workspace status glyph restated the dots beneath it; the rail restated the indentation; the indentation restated what columns say better; and the counts restated the rows. Each was removed, in that order.

The thing most likely to come off next is the **column heading row**. It is chrome that never changes on a panel whose thesis is that chrome should be almost silent, and it survives only because it is what tells a first-time reader that this is a table with columns rather than a list with odd spacing. If the panel ever feels busy, remove that before anything else.

## Copy

Write from the user's side of the screen, in the interface's voice.

- "waiting for you", not "blocked" or "BLOCKED_STATUS".
- "finished", not "completed transition to idle".
- Empty state is an invitation, not an apology: "No herdr sessions running" with a single quiet line on how to start one, never "Failed to load".
- An error says what happened and what to do, in one sentence, without apologising.
- The transient popup keeps the same vocabulary as the list, so a blocked agent that says "waiting for you" in the popup says "waiting for you" in the row tooltip too.

## Quality floor

Keyboard focus must be visible. The panel must be legible in light mode even though it is tuned for dark. Text must not truncate the identifier from the front unless it genuinely overflows, and the full `cwd` stays available on hover now that the row no longer shows it.

**A tooltip says what identifies the row and stops.** Three lines: identifier and status, the `cwd`, the pane id. A fourth line offering the `herdr session attach` remedy was added to every agent row and had to come out: it appeared whether or not anything had failed, so it was untrue most of the time, and a four-line tooltip covered a third of the panel. Advice belongs at the scope it applies to, which for attaching a client is the session, so it lives on the session header instead, once per session rather than sixteen times.

**No session may silently vanish.** Every discovered session appears, whatever state it is in: running with agents, running and not answering, running with nothing in it, or stopped. This is written down because the ledger broke it once. Its first version only ever emitted rows from inside a workspace loop, so a running session whose call failed, and which therefore arrives with no workspaces, produced no lines at all and disappeared from the panel while herdr still listed its agents. It was caught by reconciling the panel against `agent.list` across every session, which is the check to run after any change to how rows are built: **the panel's agent count must equal herdr's.** A session that vanishes is worse than one shown as broken, because the user cannot tell it apart from a broken panel.

**An idle popover must cost nothing.** Near 0 % CPU with the panel open and no state changing. This is a hard requirement, not an aspiration: it was violated at 19 % and reported at 99 %, and it is the reason there is no motion. Anything added here gets measured with `ps` over at least a minute before it is called done.
