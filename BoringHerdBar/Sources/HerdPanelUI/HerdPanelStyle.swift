import HerdKit
import NotchCore
import SwiftUI

// The tokens, vocabulary and status glyph shared by every surface that draws herd state: the ledger
// panel in this module, and the search window, status item and transient popup in the host app.
//
// These lived in `HerdListView.swift` until the ledger replaced the indented list. They moved here
// rather than staying behind in a gutted file for one reason worth stating: while the panel had its own
// copy of the palette there were two palettes in the app, and every warning in `docs/herd/DESIGN.md`
// about two surfaces disagreeing applied directly to that arrangement. One definition, in the module
// both sides can see, is the only version of this that cannot drift.
//
// Imports are SwiftUI and HerdKit only, like everything in this target, so all of it lifts into the
// boringNotch fork. The target cannot reach a host type even by accident, which is the point of it being a
// separate target rather than a naming convention.

// MARK: - Palette

/// The colour tokens for every herd surface.
///
/// **Four saturated colours, one per actionable status, and that is a change of policy.** This palette
/// used to hold exactly two, amber for blocked and a cool blue for working, on the argument that a blocked
/// agent has not failed so it deserves an invitation rather than an alarm. The user overruled both halves
/// of that: blue-for-working read as counter-intuitive next to herdr itself, which draws a *completed*
/// agent in blue, and they asked for a scheme where the hue names the state without being learned. So the
/// mapping is now red for blocked, amber for working, green for done, blue for idle, and grey for unknown.
/// `docs/herd/DESIGN.md` records the superseded reasoning; do not "restore" the two-colour rule from that
/// entry alone.
///
/// The one thing the recolour must not lose is the measured floor. Every token below clears 4.5:1 against
/// both the surface and the hover fill where it is drawn as text, and 3:1 where it is only a mark, at every
/// step of the type scale (no step reaches WCAG's 18 pt large-text exemption, so the text bar never
/// relaxes). `HerdPaletteContrastTests` pins those numbers, so a later tweak that dims a hue fails a test
/// rather than shipping.
///
/// Resolved from the environment's colour scheme rather than from `NSColor`'s dynamic providers, because
/// this module may not import AppKit. Dark is the tuned target; light exists to stay legible.
public struct HerdPalette: Sendable {
    /// Panel base, and the fix for the single worst legibility bug this design had.
    ///
    /// The token was always specified but never applied: the popover was left with whatever the system
    /// material gave it, so on a busy desktop the user's terminal text read straight through the rows. It
    /// is deliberately opaque rather than translucent. Vibrancy is worth something on a surface that
    /// floats over a photograph and nothing at all on one that floats over dense monospace text, and this
    /// panel is only ever summoned in front of the latter. Being opaque also fixes the worst-case contrast
    /// numbers, which against a bright window behind a translucent surface fell to 2.86:1 for idle text
    /// and 1.94:1 for metadata.
    ///
    /// Because there is no transparency left, `accessibilityReduceTransparency` has nothing to reduce.
    public let surface: Color
    /// Dividers and hover fills only.
    ///
    /// Never text, and never an indicator. At 1.28:1 against ``surface`` it cannot carry either, which is
    /// exactly why the agent-kind tag and the idle rings were invisible when they were drawn in it. As a
    /// background wash behind text that has its own contrast, it is fine.
    public let hairline: Color
    /// A card's own fill, one step lighter than ``surface`` — the bento notch layout's elevation model.
    ///
    /// Precomposited to a single opaque colour (``surface`` plus a flat white-5% wash, baked in rather
    /// than layered at draw time) so it stays a plain, cheap `Color` fill with no blending cost per frame
    /// and no risk of a translucent card reading differently depending on what is behind the panel — the
    /// same "opaque, not vibrant" reasoning ``surface`` itself documents. Purely decorative: unlike every
    /// other token here, nothing is ever drawn *as* `cardFill` (no text, no mark), so it carries no
    /// contrast floor of its own — what has to clear 4.5:1/3:1 is whatever is drawn on top of a card, and
    /// `HerdPaletteTests` pins those foregrounds against this fill for exactly that reason.
    public let cardFill: Color
    /// The composited hover fill.
    ///
    /// A literal value rather than ``hairline`` at an opacity, because the contrast floor on it was
    /// measured against this exact colour: ``textTertiary`` sits at 4.63:1 on it, which is the tightest
    /// margin in the palette. An opacity would make that number a guess rather than a fact.
    public let hoverFill: Color
    /// Identifiers on rows that are doing or wanting something.
    public let textPrimary: Color
    /// Session names, and the `unknown` indicator.
    public let textSecondary: Color
    /// Counts, the agent kind, workspace names, and secondary context in the search results.
    public let textTertiary: Color
    /// Identifiers on idle rows.
    ///
    /// De-emphasis is relative, not absolute, and the first two attempts at this pitched it too low. The
    /// rule the palette now follows: idle is *recessive* but never *strained to read*. Every text token
    /// clears 4.5:1 on the background it actually sits on, and the hierarchy is carried by the distance up
    /// to ``textPrimary`` rather than by pushing idle down towards the surface.
    public let textIdle: Color
    /// The identifier under the cursor, one step brighter than ``textPrimary``.
    public let identifierHover: Color
    /// An agent waiting on the human, and the app's error register.
    ///
    /// Drawn as **text** as well as a mark, and in more places than the status: the panel banner when it
    /// reports a fault, a session's stand-in line when its server did not answer, the settings window's
    /// warning rows, the shortcut field while recording, and the status item's degraded marker. So it
    /// carries the 4.5:1 text floor rather than the 3:1 mark floor, and red is a better fit for those
    /// secondary uses than the amber it replaced.
    public let blocked: Color
    /// An agent reporting completion. The one hue that means "go and look".
    ///
    /// Also drawn as text, on the identifier of a finished row, so it carries the 4.5:1 floor too.
    public let done: Color
    /// In-progress work. A mark only, never text, so the 3:1 floor applies.
    public let working: Color
    /// An agent alive with nothing in flight. A mark only.
    ///
    /// Deliberately the quietest of the four, and pitched at almost exactly the loudness of the
    /// ``textTertiary`` ring it replaced (4.49:1 against 4.63:1 on the hover fill). Idle is most of the
    /// panel on an ordinary day, so a hue here is the one that could drown the other three by sheer count;
    /// matching the loudness of what was already there is what stops that. It stays hollow and small too,
    /// so shape still carries the de-emphasis and colour only names the state.
    public let idle: Color

    /// The tuned, primary target.
    ///
    /// Measured WCAG 2.1 ratios against ``surface`` at `#16171A`. Every font in the app is 12 pt or
    /// smaller, so 4.5:1 is the bar for all text and 3:1 for non-text indicators.
    ///
    /// | token | on surface | on hover `#202226` | floor |
    /// |---|---|---|---|
    /// | `textPrimary` | 14.76 | 13.12 | 4.5 |
    /// | `textSecondary` | 6.80 | 6.04 | 4.5 |
    /// | `textIdle` | 6.48 | 5.76 | 4.5 |
    /// | `textTertiary` | 5.21 | 4.63 | 4.5 |
    /// | `blocked` `#FF5252` | 5.62 | 4.99 | 4.5 |
    /// | `done` `#2ECC71` | 8.53 | 7.58 | 4.5 |
    /// | `working` `#FFA53C` | 9.13 | 8.12 | 3.0 |
    /// | `idle` `#4D8FD0` | 5.25 | 4.67 | 3.0 |
    ///
    /// The greys are untouched. The four status hues were re-picked for a punchier, more vibrant read as
    /// glowing dots in the notch — brighter true red, a more vivid warm amber, a richer emerald and a more
    /// saturated blue — each re-measured rather than eyeballed brighter, so the floor above still holds.
    /// `idle`'s new value is deliberately the smallest jump of the four: it is pinned by
    /// `HerdPaletteTests.idleStaysRecessive` to stay no louder than ``textTertiary`` (5.21 + 0.1 headroom),
    /// so "brighter" here means more saturated within that same narrow contrast band rather than a bigger
    /// jump in luminance the other three hues could afford.
    public static let dark = HerdPalette(
        surface: Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255),
        hairline: Color(red: 0x2A / 255, green: 0x2C / 255, blue: 0x31 / 255),
        // `surface` (`#16171A`) composited under a flat white-5% wash: `channel * 0.95 + 255 * 0.05`,
        // rounded — `#222325`, one visible step lighter than `surface` without approaching `hairline`.
        cardFill: Color(red: 0x22 / 255, green: 0x23 / 255, blue: 0x25 / 255),
        hoverFill: Color(red: 0x20 / 255, green: 0x22 / 255, blue: 0x26 / 255),
        textPrimary: Color(red: 0xE8 / 255, green: 0xE9 / 255, blue: 0xEC / 255),
        textSecondary: Color(red: 0x9A / 255, green: 0xA0 / 255, blue: 0xA8 / 255),
        textTertiary: Color(red: 0x84 / 255, green: 0x8B / 255, blue: 0x94 / 255),
        textIdle: Color(red: 0x96 / 255, green: 0x9C / 255, blue: 0xA5 / 255),
        identifierHover: .white,
        blocked: Color(red: 0xFF / 255, green: 0x52 / 255, blue: 0x52 / 255),
        done: Color(red: 0x2E / 255, green: 0xCC / 255, blue: 0x71 / 255),
        working: Color(red: 0xFF / 255, green: 0xA5 / 255, blue: 0x3C / 255),
        idle: Color(red: 0x4D / 255, green: 0x8F / 255, blue: 0xD0 / 255)
    )

    /// Light mode: the same ramp inverted. Legible, not tuned.
    ///
    /// Every text token is darker than `#6F6F6F`, which is the point at which 4.5:1 is reached against
    /// this surface, so the same floor holds here. The previous light `textTertiary` at `#9AA0A8` was well
    /// under it.
    ///
    /// | token | on surface | on hover `#E4E5E9` | floor |
    /// |---|---|---|---|
    /// | `blocked` `#BE1732` | 5.59 | 4.97 | 4.5 |
    /// | `done` `#09703A` | 5.54 | 4.92 | 4.5 |
    /// | `working` `#AE5A10` | 4.40 | 3.91 | 3.0 |
    /// | `idle` `#2A78AF` | 4.27 | 3.79 | 3.0 |
    ///
    /// As in dark, these four were re-picked more vivid/saturated in the same direction as ``dark``'s own
    /// re-pick, staying inside the floors this table already enforced — `working` still clears only the
    /// 3:1 mark floor, not 4.5:1, which is correct only because `working` is never drawn as text; if that
    /// ever changes, this value has to change with it.
    ///
    /// `idle` keeps `HerdPaletteTests.idleStaysRecessive`'s emphasis order: it sits below `working`'s own
    /// 4.40, the tightest of the other three ratios above, the same "idle is louder than `working` and the
    /// order inverts" failure the light palette's previous re-pick documented here — that risk is still
    /// live any time `idle` and `working` are re-picked in the same pass, not just the first time.
    public static let light = HerdPalette(
        surface: Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255),
        hairline: Color(red: 0xD6 / 255, green: 0xD8 / 255, blue: 0xDE / 255),
        // Same `channel * 0.95 + 255 * 0.05` composite as ``dark``'s own `cardFill`, applied to this
        // palette's own `surface` (`#F2F2F4`) — `#F3F3F5`.
        cardFill: Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF5 / 255),
        hoverFill: Color(red: 0xE4 / 255, green: 0xE5 / 255, blue: 0xE9 / 255),
        textPrimary: Color(red: 0x1A / 255, green: 0x1C / 255, blue: 0x20 / 255),
        textSecondary: Color(red: 0x4A / 255, green: 0x50 / 255, blue: 0x5A / 255),
        textTertiary: Color(red: 0x5F / 255, green: 0x65 / 255, blue: 0x6E / 255),
        textIdle: Color(red: 0x54 / 255, green: 0x5A / 255, blue: 0x64 / 255),
        identifierHover: .black,
        blocked: Color(red: 0xBE / 255, green: 0x17 / 255, blue: 0x32 / 255),
        done: Color(red: 0x09 / 255, green: 0x70 / 255, blue: 0x3A / 255),
        working: Color(red: 0xAE / 255, green: 0x5A / 255, blue: 0x10 / 255),
        idle: Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xAF / 255)
    )

    /// Picks the palette for a colour scheme.
    ///
    /// - Parameter scheme: The environment's current scheme.
    /// - Returns: ``dark`` for dark mode, ``light`` otherwise.
    public static func resolving(_ scheme: ColorScheme) -> HerdPalette {
        scheme == .dark ? .dark : .light
    }

    /// Accent for a status, or `nil` when the status draws no colour.
    ///
    /// Every state herdr can actually report now has a hue, `idle` included; it used to return `nil` there
    /// on the argument that idle is the absence of information, and the user asked for a scheme where each
    /// state is named by its colour instead.
    ///
    /// `unknown` stays colourless, and that is the one part of the old rule worth keeping. A hue is a claim
    /// about what the agent is doing, and `unknown` is precisely the case where the app has no such claim to
    /// make: it means herdr did not classify the pane, or reported a state this build predates. Grey is the
    /// honest answer, and it is also what makes `unknown` visibly different from the four states that are
    /// real rather than merely one more colour to learn.
    ///
    /// - Parameter status: The status to colour.
    /// - Returns: A colour, or `nil` for `unknown`, which callers draw in a grey.
    public func accent(for status: AgentStatus) -> Color? {
        switch status {
        case .blocked: blocked
        case .done: done
        case .working: working
        case .idle: idle
        case .unknown: nil
        }
    }

    /// Accent for a ``BatteryTier``, the one home for this mapping so the utility band's battery ring and
    /// its threshold toasts can never disagree on what a tier looks like.
    ///
    /// `.warning` and `.critical` share ``blocked``'s red deliberately: a 10% and a 5% reading are meant to
    /// read equally urgent, not on a graduated scale.
    ///
    /// - Parameter tier: The tier to colour.
    /// - Returns: ``done`` for `.healthy`, ``working`` for `.low`, ``blocked`` for `.warning`/`.critical`.
    public func color(for tier: BatteryTier) -> Color {
        switch tier {
        case .healthy: done
        case .low: working
        case .warning, .critical: blocked
        }
    }
}

// MARK: - Vocabulary

public extension AgentStatus {
    /// How this state is described to the user, in the interface's voice.
    ///
    /// "waiting for you" rather than "blocked": the row is addressed to the person reading it, and the
    /// state is an invitation rather than a fault. The same words are used in the row tooltip, the
    /// VoiceOver label and the transient popup, so one state never has two names.
    var phrase: String {
        switch self {
        case .blocked: "waiting for you"
        case .done: "done"
        case .working: "working"
        case .idle: "idle"
        case .unknown: "state unknown"
        }
    }
}

public extension HerdAgent {
    /// The identifier shown wherever an agent is named.
    ///
    /// Prefers herdr's own tab label, which is what the user named the work (`catalog_version_diff`), and
    /// falls back to the working directory's basename (`catalog-svd`) only when there is no label. No
    /// cleverness beyond that: a tab genuinely labelled `claude` is shown as `claude`, because that is
    /// what herdr itself shows and second-guessing it would be a lie.
    var displayIdentifier: String {
        if let tabLabel, !tabLabel.isEmpty { return tabLabel }
        return cwdBasename
    }

    /// Last path component of the working directory.
    var cwdBasename: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.isEmpty ? "/" : (trimmed.split(separator: "/").last.map(String.init) ?? trimmed)
    }
}

/// The second line of an agent row: session, kind, then activity, joined with ` · `.
///
/// `default` sessions and `claude` agents are the common case, so they are omitted rather than repeated
/// on every row. Empty parts are dropped too.
///
/// - Returns: `nil` when nothing remains, so the caller can render a same-height placeholder.
public func agentRowDetail(sessionName: String, kind: String, activityText: String?) -> String? {
    var parts: [String] = []
    if !sessionName.isEmpty, sessionName != "default" { parts.append(sessionName) }
    if !kind.isEmpty, kind != "claude" { parts.append(kind) }
    if let activityText, !activityText.isEmpty { parts.append(activityText) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

// MARK: - Metrics

/// Geometry for the search results list.
///
/// These numbers described the panel's indentation ladder until the ledger replaced it with columns. The
/// search window still uses them, so they stay, but they are now search geometry rather than panel
/// geometry, and the names that referred to the ladder have been left alone rather than renamed: the
/// search rows genuinely do hang a status dot in a gutter to the left of an identifier, which is what the
/// ladder names describe. The ledger's own furniture is ``HerdLedgerMetric``, and its column widths are
/// measured from the values on screen rather than declared, in ``HerdLedgerColumns``.
public enum HerdMetric {
    /// Left margin. The session name starts here.
    public static let inset: CGFloat = 12

    /// One step of the nesting ladder.
    public static let indentUnit: CGFloat = 14

    /// Gap between the inset and the workspace name. Wider than ``indentUnit`` because the status dots
    /// hang in this gutter and need more clearance either side than a step of text does.
    public static let gutter: CGFloat = 22

    /// Leading edge of workspace text.
    public static var workspaceIndent: CGFloat { inset + gutter }

    /// Leading edge of an agent's tab label, one step in from the workspace above it.
    public static var agentIndent: CGFloat { workspaceIndent + indentUnit }

    /// Width of the column the status dot is centred in. Sized for the largest, blocked dot.
    public static let dotColumn: CGFloat = 10

    /// Space between the dot column and the identifier beside it. Tight on purpose: at a wider spacing the
    /// dot read as a stray mark in the margin rather than as that row's status.
    public static let dotGap: CGFloat = 6

    /// Leading edge of the dot column, derived so the dot sits immediately left of the identifier.
    public static var dotIndent: CGFloat { agentIndent - dotGap - dotColumn }

    /// Width of the right-hand count column, so counts form a real column rather than floating.
    public static let countColumn: CGFloat = 22

    /// Search window width.
    public static let panelWidth: CGFloat = 360
}

// MARK: - Status dot

/// The status glyph used by the search results.
///
/// Five renderings, in descending loudness. `blocked` is a filled red disc with a soft glow that spills
/// past its column, which is what makes a waiting agent impossible to miss in peripheral vision. `done` is
/// a filled green disc one step down, loud because a finished agent is the second thing worth walking over
/// to. `working` is a smaller filled amber disc. `idle` and `unknown` are hollow rings, blue and grey.
///
/// **There is no motion here, and that is a measured decision rather than a preference.** The design
/// originally called for a working dot that breathes on a repeating two second cycle. A repeating SwiftUI
/// animation never completes, so its transaction stays pending, so `GraphHost.flushTransactions` runs on
/// every pass of the run loop and the process never sleeps. Measured with one working agent in a forty row
/// popover: 19 % of a core with the panel merely open, against 0.3 % with the animation removed, and the
/// user saw it reach 99 % on a larger herd. Retriggering a *finite* animation from the poll tick was tried
/// and measured no better, at 18 %, because the cost is not the repeat, it is having any animation in
/// flight inside a popover whose backdrop AppKit recomposites every frame. Since fill and colour already
/// separate working from idle unambiguously, the motion was the part that could go. Bringing it back needs
/// a rendering path outside the SwiftUI view graph, which this module cannot reach without AppKit.
///
/// The ledger draws its own gutter sigils rather than reusing this, because a table wants shapes that
/// differ in outline and not only in fill, and because its gutter is 13 pt rather than a 10 pt dot column.
/// Both draw from the same palette, so amber still means one thing everywhere.
public struct HerdStatusDot: View {
    /// The status to draw.
    public let status: AgentStatus

    /// Tokens for the current scheme.
    public let palette: HerdPalette

    /// Creates the glyph.
    ///
    /// - Parameters:
    ///   - status: The status to draw.
    ///   - palette: Tokens for the current scheme.
    public init(status: AgentStatus, palette: HerdPalette) {
        self.status = status
        self.palette = palette
    }

    public var body: some View {
        switch status {
        case .blocked:
            Circle()
                .fill(palette.blocked)
                .frame(width: 9, height: 9)
                .shadow(color: palette.blocked.opacity(0.6), radius: 4)
                .shadow(color: palette.blocked.opacity(0.3), radius: 9)
        case .done:
            // Filled and a size between blocked and working, with no glow. The glow is reserved for the one
            // state that needs the user *now*; a finished agent wants to be found on the next glance, not
            // to interrupt the current one.
            Circle()
                .fill(palette.done)
                .frame(width: 8, height: 8)
        case .working:
            // Filled rather than ringed, which is what separates it from idle at a glance in the absence
            // of the breath, and a size step up from idle for the same reason.
            Circle()
                .fill(palette.working)
                .frame(width: 7, height: 7)
        case .idle:
            // Drawn in the `idle` blue, not `hairline`. A `hairline` ring measured 1.28:1 against the
            // surface, well under the 3:1 a non-text indicator needs, so the thing that told the user an
            // agent was alive was effectively invisible. The blue is pitched at the loudness of the
            // `textTertiary` grey it replaced, so naming the state costs no extra emphasis. Idle stays
            // recessive by being hollow and small; it does not also need to be unreadable.
            Circle()
                .strokeBorder(palette.idle, lineWidth: 1)
                .frame(width: 6, height: 6)
        case .unknown:
            // A step louder than idle, because "I cannot tell" is worth noticing where "nothing is
            // happening" is not.
            Circle()
                .strokeBorder(palette.textSecondary, lineWidth: 1.5)
                .frame(width: 6, height: 6)
        }
    }
}
