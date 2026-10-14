// swift-tools-version:6.0

import PackageDescription

/// BoringHerdBar is a standalone `LSUIElement` menu bar app that shows every herdr session and its
/// agents with live statuses.
///
/// It exists as a SwiftPM executable rather than an Xcode target for one reason: Xcode is not
/// installed on this machine, so `xcodebuild`, `actool` and the Metal compiler are all unavailable.
/// `swiftc` from the Command Line Tools compiles SwiftUI and AppKit against the CLT SDK perfectly
/// well, so the only thing SwiftPM cannot do is assemble the `.app` bundle. `build.sh` does that by
/// hand.
///
/// Consequences of the no-Xcode constraint, all deliberate:
///
/// - No asset catalog. Every icon is an SF Symbol drawn in code and every colour is defined in Swift,
///   because `actool` cannot compile an `Assets.xcassets`.
/// - No xib or storyboard, because `ibtool` is a stub. The status item, popover and menu are all
///   built programmatically.
/// - No resources at all, which is why this target declares none.
///
/// The app is not sandboxed (a hand-assembled ad-hoc-signed bundle has no entitlements), so it reads
/// the herdr sockets directly through ``HerdKit`` rather than through an XPC helper.
let package = Package(
    name: "BoringHerdBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../HerdKit")
    ],
    targets: [
        // The panel's content, and the only target that lifts into the boringNotch fork. It depends on
        // HerdKit and NotchCore (the latter pure Foundation, for `BatteryTier` alone — see
        // `HerdPalette.color(for:)`) and nothing else, which turns the "SwiftUI plus pure-value data only"
        // rule into something the build system enforces rather than something a comment asks for: an
        // accidental `import AppKit` in the panel view fails to compile here instead of failing review.
        .target(
            name: "HerdPanelUI",
            dependencies: ["HerdKit", "NotchCore"]
        ),
        // The global shortcut as a value: its Carbon key code and modifier mask, how it is displayed, and
        // how it round-trips through `UserDefaults`. A target of its own for one reason, testability. Now
        // that the shortcut is user-configurable, the two things that can silently be wrong are a stored
        // value that reads back as a different shortcut and a label that names the wrong keys, and both are
        // pure functions over integers. They cannot be tested from inside the executable target, because
        // SwiftPM cannot import a module whose entry point is top-level code in `main.swift`.
        //
        // It imports Carbon.HIToolbox, which is why it does not live in HerdKit (pure Foundation, shared
        // with the parked fork's XPC helper) or in HerdPanelUI (SwiftUI and HerdKit only, lifts into the
        // fork verbatim). It is host-side code, so it lives in the host's package.
        .target(
            name: "HerdShortcut"
        ),
        // The Carbon hot-key registrar as a library of its own, extracted out of the `BoringHerdBar`
        // executable in HerdNotch's Phase 2 so the notch app can register the same fn-fn shortcut without
        // depending on the menu-bar app's executable target (SwiftPM cannot import one). It depends on
        // `HerdShortcut` for the value it registers and nothing else, the same "host-side Carbon glue"
        // reasoning `HerdShortcut`'s own doc comment gives for not living in HerdKit or HerdPanelUI.
        .target(
            name: "HerdHotKey",
            dependencies: ["HerdShortcut"]
        ),
        // The glitch-free notch state machine for the forthcoming HerdNotch app: event in, state and
        // effects out, no clock, no timer, no pointer monitor. Foundation only, and a target of its own for
        // the same reason as HerdShortcut, testability without a window server. It imports nothing from
        // AppKit, SwiftUI or CoreGraphics on purpose, so the pure reducer cannot accidentally reach for a
        // `CALayer` or a real `CGDirectDisplayID`; the AppKit composition root that eventually consumes it
        // lives in a later phase's executable target.
        .target(
            name: "NotchCore"
        ),
        // The per-display notch-vs-pill classifier for the forthcoming HerdNotch app: plain-value
        // metrics in, a plain-value layout out, no clock, no window server. CoreGraphics only (for
        // `CGRect`/`CGFloat`/`CGSize`) and nothing from AppKit, so the dynamic reclassification a notched
        // MacBook needs when it is mirrored or dropped into a scaled resolution — the risk this target
        // exists to isolate — is an ordinary value-in, value-out function a test can drive with numbers
        // instead of a real screen. The AppKit layer that extracts these values from a live `NSScreen` is
        // a thin adapter living in a later phase's executable target, the same split NotchCore uses for
        // its `CGDirectDisplayID` boundary.
        .target(
            name: "NotchGeometry"
        ),
        // The pieces of the original `BoringHerdBar` executable that are genuinely reusable by any host
        // app, not just this one: pane search (the window, the view, the fuzzy-search field), settings
        // (the preferences store, the form, the shortcut recorder) and focusing an agent's terminal.
        // Extracted so `HerdNotch` can share them rather than reimplement or, worse, silently regress
        // them (as happened when its fn-fn hotkey shipped without the search window at all). It carries no
        // dependency back on either executable target — SwiftPM cannot import one anyway — and takes
        // `HerdBarModel`/`NotchHerdModel`-shaped inputs through the small `HerdSearchSnapshotSource`
        // protocol rather than naming either concrete type.
        .target(
            name: "HerdHost",
            dependencies: ["HerdKit", "HerdPanelUI", "HerdShortcut", "HerdHotKey"]
        ),
        .executableTarget(
            name: "BoringHerdBar",
            dependencies: ["HerdKit", "HerdPanelUI", "HerdShortcut", "HerdHotKey", "HerdHost"]
        ),
        // The Phase 1 payoff: a real, glitch-free notch window built as a FAITHFUL executor around
        // `NotchCore`'s reducer and `NotchGeometry`'s classifier. It depends on both pure libraries plus
        // `HerdPanelUI` for `HerdPalette` alone (the shell's look, not the ledger view itself — that
        // arrives in a later phase). No herd content, no Spotify, no hotkey yet: this target's only job is
        // proving the open/close/hover/hysteresis machinery never sticks open, never flickers and never
        // spins CPU, on both a notched and a notchless display.
        .executableTarget(
            name: "HerdNotch",
            dependencies: [
                "NotchCore", "NotchGeometry", "HerdPanelUI", "HerdKit", "HerdHotKey", "HerdShortcut", "HerdHost",
                "UsageKit"
            ]
        ),
        // Read-only plan-usage limits for Claude, Codex, OpenCode and Antigravity, ported from OpenUsage (MIT).
        // Foundation, CryptoKit and HerdKit (its blocking process runner) only, so it has no window server or
        // AppKit dependency; credentials are only ever read, never refreshed or written.
        .target(
            name: "UsageKit",
            dependencies: ["HerdKit"]
        ),
        // Debug entry for UsageKit: prints each provider's live state and windows, never a token or account id.
        .executableTarget(
            name: "UsageProbe",
            dependencies: ["UsageKit"]
        ),
        // Only the column measurement is tested here, and only because it is arithmetic over strings
        // rather than a view: it decides the panel's width before anything is laid out, so it can be
        // checked without a window, a screen or an appearance. The views themselves are still verified by
        // rendering them to a PNG, since there is no assertion that usefully stands in for looking.
        //
        // Run it with the same framework search path HerdKit's tests need, for the same reason:
        //
        //     FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
        //     swift test -Xswiftc -F -Xswiftc $FW \
        //                -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlay-search \
        //                -Xlinker -rpath -Xlinker $FW
        .testTarget(
            name: "HerdPanelUITests",
            dependencies: ["HerdPanelUI"]
        ),
        // Run with the same flags, for the same reason.
        .testTarget(
            name: "HerdShortcutTests",
            dependencies: ["HerdShortcut"]
        ),
        .testTarget(
            name: "HerdHotKeyTests",
            dependencies: ["HerdHotKey", "HerdShortcut"]
        ),
        // Every reducer transition, run with no window server at all: NotchCore is pure Foundation, so
        // these tests are ordinary value-in-value-out assertions with no framework search path needed.
        .testTarget(
            name: "NotchCoreTests",
            dependencies: ["NotchCore"]
        ),
        // Every classification and frame-derivation rule, run with no window server at all: NotchGeometry
        // is pure CoreGraphics-over-values, so these tests are ordinary value-in-value-out assertions,
        // same as NotchCoreTests above.
        .testTarget(
            name: "NotchGeometryTests",
            dependencies: ["NotchGeometry"]
        ),
        // Mapper, credential-parsing and cooldown tests over fixture JSON and fakes: no network, no real tokens.
        .testTarget(
            name: "UsageKitTests",
            dependencies: ["UsageKit"]
        )
    ]
)
