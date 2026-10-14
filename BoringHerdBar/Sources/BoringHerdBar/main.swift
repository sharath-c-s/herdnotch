import AppKit

// Process entry point.
//
// Explicit `NSApplication` setup rather than `@main` on a SwiftUI `App`, for two reasons. First, the
// SwiftUI `MenuBarExtra` scene cannot host an `NSPopover`, and an `NSPopover` is what supplies
// click-outside dismissal and correct multi-display placement without any code here. Second, there is
// no Xcode on this machine and therefore no generated main: this file is the whole launch sequence,
// which makes it worth being able to read it in one screen.
//
// `LSUIElement` in the bundle's Info.plist is what actually keeps the Dock icon away;
// `AppDelegate.applicationDidFinishLaunching` also sets `.accessory` so a bare `swift run` behaves
// the same way.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
