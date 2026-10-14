// swift-tools-version:6.0

import PackageDescription

/// HerdKit is the herdr data layer for boring-herd.
///
/// It is deliberately a standalone SwiftPM package with no SwiftUI, AppKit or XPC dependency: pure
/// Foundation plus Darwin. That keeps it buildable and testable without Xcode, and lets both the
/// sandboxed app and the unsandboxed XPC helper link the exact same models and JSON coders.
///
/// Running the tests before Xcode is installed
/// -------------------------------------------
/// The tests use swift-testing. `Testing.framework` ships with the Command Line Tools, but a CLT
/// install has no Xcode platform directory, so `xcrun --show-sdk-platform-path` fails and SwiftPM
/// cannot derive a framework search path. Until Xcode 26 is installed and selected, run:
///
///     FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
///     swift test -Xswiftc -F -Xswiftc $FW \
///                -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlay-search \
///                -Xlinker -rpath -Xlinker $FW
///
/// The flags have to be global rather than declared here: SwiftPM's generated test-runner target
/// guards its swift-testing entry point behind `#if canImport(Testing)`, and per-target settings in
/// this manifest do not reach that generated target, so a manifest-only fix makes `swift test` exit
/// zero having run nothing. `-disable-cross-import-overlay-search` is needed because the CLT copy of
/// the `_Testing_Foundation` cross-import overlay ships a binary but no `.swiftinterface`; the overlay
/// only adds convenience API these tests do not use. Once Xcode is selected, plain `swift test` works
/// and none of this applies.
let package = Package(
    name: "HerdKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdKit", targets: ["HerdKit"])
    ],
    targets: [
        .target(name: "HerdKit"),
        .testTarget(
            name: "HerdKitTests",
            dependencies: ["HerdKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
