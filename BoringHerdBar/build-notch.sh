#!/bin/bash
#
# Assembles HerdNotch.app from the SwiftPM executable, the same hand-rolled way `build.sh` assembles
# BoringHerdBar.app — see that script's header for why a bundle has to be built by hand at all (no Xcode,
# no `actool`, no `ibtool` on this machine).
#
# HerdNotch is BoringHerdBar's eventual successor (see the plan's "Runtime relationship to BoringHerdBar"
# section), not a rename of it: both executable targets stay in `Package.swift`, this script and `build.sh`
# both keep working, and the two apps are meant to be run one at a time, never together.
#
# Idempotent: the bundle is removed and rebuilt from scratch on every run.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="HerdNotch"
BUNDLE_ID="com.boringherd.HerdNotch"
VERSION="${HERDNOTCH_VERSION:-0.1.0}"
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

# Unlike `build.sh`, a missing icon here is skipped rather than a hard failure: HerdNotch has not had one
# drawn yet, and Phase 1's job is proving the notch shell, not artwork. Regenerate one with
# `icon/make-icon.swift` (pointed at this app name) whenever it exists, and this step starts copying it
# automatically.
if [ -f "$ICNS_PATH" ]; then
    cp "$ICNS_PATH" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
else
    echo "==> no icon at $ICNS_PATH, skipping (HerdNotch has none drawn yet)"
fi

# The Apple-signed-interpreter now-playing helper: a loose .swift SOURCE file, deliberately never compiled
# by this script (or anything else) — see HelperScripts/mediaremote-helper.swift's own top-of-file
# documentation for why running it interpreted, via `xcrun swift`, is what lets it read system-wide
# now-playing state that HerdNotch.app's own ad-hoc-signed process cannot. Bundled as a plain resource so
# SystemNowPlayingService can locate it at a stable path relative to the running app.
HELPER_SCRIPT_PATH="$PWD/HelperScripts/mediaremote-helper.swift"
if [ -f "$HELPER_SCRIPT_PATH" ]; then
    cp "$HELPER_SCRIPT_PATH" "$APP_DIR/Contents/Resources/mediaremote-helper.swift"
else
    echo "error: expected helper script at $HELPER_SCRIPT_PATH" >&2
    exit 1
fi

# ungive/mediaremote-adapter (BSD-3-Clause, vendored; see Vendor/mediaremote-adapter/VENDORED.md): a perl
# script plus a framework that /usr/bin/perl (Apple-signed, com.apple.perl5) dlopens, which is what lets the
# now-playing READ path work without Xcode CLT. The framework is bundled but never linked. Built here with
# plain clang (no CMake, no Xcode project). Built for arm64e + x86_64 to match /usr/bin/perl's own slices;
# arm64e is observed to load under perl on Apple silicon, x86_64 (Intel) is untested.
ADAPTER_SRC="$PWD/Vendor/mediaremote-adapter"
ADAPTER_FW="$APP_DIR/Contents/Frameworks/MediaRemoteAdapter.framework"
if [ ! -f "$ADAPTER_SRC/bin/mediaremote-adapter.pl" ]; then
    echo "error: vendored adapter missing at $ADAPTER_SRC" >&2
    exit 1
fi
echo "==> building MediaRemoteAdapter.framework (clang, arm64e + x86_64)"
mkdir -p "$ADAPTER_FW/Versions/A/Resources"
ADAPTER_SOURCES=("$ADAPTER_SRC"/src/adapter/*.m "$ADAPTER_SRC"/src/private/*.m "$ADAPTER_SRC"/src/utility/*.m)
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -arch arm64e -arch x86_64 -mmacosx-version-min=14.0 \
    -I "$ADAPTER_SRC/include" -I "$ADAPTER_SRC/src" "${ADAPTER_SOURCES[@]}" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    -o "$ADAPTER_FW/Versions/A/MediaRemoteAdapter"
cat > "$ADAPTER_FW/Versions/A/Resources/Info.plist" <<'FWPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key>
    <string>com.vandenbe.MediaRemoteAdapter</string>
    <key>CFBundleName</key>
    <string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.7</string>
    <key>CFBundleVersion</key>
    <string>0.7.7</string>
</dict>
</plist>
FWPLIST
ln -s A "$ADAPTER_FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$ADAPTER_FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$ADAPTER_FW/Resources"
codesign --force --sign - "$ADAPTER_FW"
ADAPTER_ARCHS="$(lipo -archs "$ADAPTER_FW/Versions/A/MediaRemoteAdapter")"
echo "==> adapter architectures: $ADAPTER_ARCHS"
case " $ADAPTER_ARCHS " in
    *" arm64e "*) ;;
    *) echo "error: adapter framework lacks arm64e (got: $ADAPTER_ARCHS)" >&2; exit 1 ;;
esac
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP_DIR/Contents/Resources/mediaremote-adapter.pl"
cp "$ADAPTER_SRC/LICENSE" "$APP_DIR/Contents/Resources/mediaremote-adapter-LICENSE"
cp ../ThirdPartyLicenses/* "$APP_DIR/Contents/Resources/"
cp ../NOTICE.md "$APP_DIR/Contents/Resources/NOTICE.md"

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
    <string>Herd Notch</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
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
    <!-- Not exercised by Phase 1 (no AppleScript call is ever made yet), but kept present now rather than
         added later: Phase 3's Spotify transport control needs this key to avoid the exact silent
         Automation-consent failure BoringHerdBar's own build.sh documents at length for its own
         terminal-raise feature, and a rebuild-and-resign later is a worse time to discover a missing
         usage string than a key that costs nothing to carry now. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Herd Notch needs to control other apps to drive Spotify playback from the notch.</string>
    <!-- Required for EKEventStore.requestFullAccessToReminders(completion:) to raise the consent prompt
         at all, the same "the usage string is the text of a prompt that is never shown without it" trap
         HerdTerminalWindowLocator.permissionToAutomate(bundleId:)'s own documentation names for Apple
         events: without this key, TCC declines to prompt and RemindersService.start() reads back
         .denied on every launch with no dialog ever appearing. This app carries no App Sandbox
         entitlement, so no com.apple.security.personal-information.reminders sandbox entitlement is
         needed alongside it -- that gate is a sandbox concept this build never opts into. -->
    <key>NSRemindersUsageDescription</key>
    <string>Herd Notch needs Reminders access to show and add reminders from the notch.</string>
</dict>
</plist>
PLIST

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Same entitlement, same hardened-runtime signing recipe as `build.sh`; see that script's comments for the
# full explanation of why the entitlement is required under the hardened runtime and why the plist is
# written outside the bundle.
ENTITLEMENTS="$(mktemp -t HerdNotch.entitlements)"
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

codesign --verify --strict "$APP_DIR"
if ! codesign -d --entitlements - --xml "$APP_DIR" 2>/dev/null \
    | grep -q "com.apple.security.automation.apple-events"; then
    echo "error: apple-events entitlement missing from the signature" >&2
    exit 1
fi

echo "built: $APP_DIR"
