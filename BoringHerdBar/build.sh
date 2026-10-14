#!/bin/bash
#
# Assembles BoringHerdBar.app from the SwiftPM executable.
#
# SwiftPM emits a bare Mach-O binary, and a bare binary cannot own an NSStatusItem: LaunchServices
# only honours LSUIElement, and AppKit only gives a process a menu bar presence, when the executable
# lives inside a bundle with an Info.plist. So this script builds the binary, writes the plist,
# copies the binary in, and ad-hoc signs the result.
#
# There is no asset catalog step because `actool` ships as a stub in a Command Line Tools install.
# Every icon *inside* the app is an SF Symbol drawn in code, so there is nothing to compile, and the
# app icon is a committed `.icns` built by `icon/make-icon.swift` through `iconutil`, which unlike
# `actool` is present in Command Line Tools. Regenerate it by hand after editing that script; it is not
# rebuilt here, because artwork changes about never and an ordinary build should not depend on AppKit
# rendering.
#
# Idempotent: the bundle is removed and rebuilt from scratch on every run, so a stale binary or a
# stale plist key can never survive into the next build.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BoringHerdBar"
BUNDLE_ID="com.boringherd.BoringHerdBar"
VERSION="0.1.0"
APP_DIR="$PWD/$APP_NAME.app"
ICNS_PATH="$PWD/icon/$APP_NAME.icns"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "error: expected executable at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Hard-failed rather than skipped. An app whose icon silently goes missing looks like a broken install
# in the Finder and in Login Items, and the difference between "no icon yet" and "the icns stopped being
# copied" is exactly the kind of thing nobody notices for a month.
if [ ! -f "$ICNS_PATH" ]; then
    echo "error: missing $ICNS_PATH; regenerate it with: swift icon/make-icon.swift" >&2
    exit 1
fi
cp "$ICNS_PATH" "$APP_DIR/Contents/Resources/$APP_NAME.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Boring Herd Bar</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <!-- Named without the .icns extension, which is what CFBundleIconFile expects. This app is
         LSUIElement so it has no Dock tile, but the icon is still what Finder, the Login Items list in
         System Settings, and any "open with" list show, and those are precisely where a user goes to
         start it after a reboot. -->
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>boring-herd</string>
    <!-- Required before the process may send an Apple event. Without this key macOS does not show the
         Automation consent prompt, it terminates the process, so the cross-session window raise would
         have taken the whole app down the first time a user clicked a row in a session their terminal
         was not attached to. The string is what appears in that prompt, so it says why. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Boring Herd Bar needs to control your terminal to bring the window showing a herdr session to the front. Without this, selecting an agent in a session your terminal is not currently showing appears to do nothing.</string>
</dict>
</plist>
PLIST

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# The entitlement is what makes the cross-session window raise work at all, and its absence was the
# whole of the bug where clicking a row in a session the terminal was not showing did nothing.
#
# `--options runtime` below enables the hardened runtime, and under the hardened runtime a process may
# not send Apple events unless it carries `com.apple.security.automation.apple-events`. The denial
# happens inside the sending process, before TCC is consulted: `NSAppleScript` returns -1743
# ("Not authorized to send Apple events to iTerm") on the very first execution, no consent prompt is
# ever shown, nothing appears in the Automation list in System Settings, and `tccd` logs nothing at
# all. `NSAppleEventsUsageDescription` in the Info.plist does not help, because that string is only the
# text of a prompt that never happens.
#
# The failure was invisible in testing because a build launched straight from a shell inherits the
# calling terminal's own Automation grant through TCC's responsible-process attribution, so the raise
# worked there and only failed once LaunchServices launched the bundle as its own responsible process,
# which is how a user always launches it.
#
# The plist is written outside the bundle and deleted afterwards. Inside it, it would be a resource the
# signature covers, so deleting it post-signing would invalidate the very signature it produced.
ENTITLEMENTS="$(mktemp -t BoringHerdBar.entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
cat > "$ENTITLEMENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTS

echo "==> codesign (ad-hoc, apple-events entitlement)"
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP_DIR"

# Checked rather than assumed: a build that signs without the entitlement looks identical from the
# outside and fails only at the moment the user clicks a row, which is the exact bug this replaces.
codesign --verify --strict "$APP_DIR"
if ! codesign -d --entitlements - --xml "$APP_DIR" 2>/dev/null \
    | grep -q "com.apple.security.automation.apple-events"; then
    echo "error: apple-events entitlement missing from the signature; the window raise would silently fail" >&2
    exit 1
fi

echo "built: $APP_DIR"
