// Generates HerdNotch.icns from code, with no Xcode and no asset catalog — the exact same reasoning
// `make-icon.swift` documents at its own top: only Command Line Tools are required for this whole
// project's build, `iconutil` (unlike `actool`) ships with them, so an `.iconset` directory of PNGs plus
// `iconutil -c icns` gets there with no Xcode at all.
//
// The output is committed rather than generated during `build-notch.sh`, for the same reason
// `BoringHerdBar.icns` is committed rather than `BoringHerdBar.app`'s own build regenerating it: an
// ordinary build should not depend on AppKit rendering and `iconutil` for artwork that changes about
// never, and a committed `.icns` means `build-notch.sh` only has to copy a file. Run this by hand after
// editing the drawing, and commit the result:
//
//     swift icon/make-herdnotch-icon.swift && bash build-notch.sh
//
// This file may import AppKit freely, for the same "build tool, not an app target" reason
// `make-icon.swift` documents.
//
// MARK: - What the icon is
//
// The icon is **the collapsed peek**: the one thing every HerdNotch install shows all the time, the pill
// itself. A near-black plate the same `surface` shade the panel is (matching `make-icon.swift`'s own
// "the icon and the panel are seen within a second of each other" reasoning), with the physical notch's
// own silhouette — flat top, rounded bottom corners, cut straight into the plate's top edge — and a single
// glowing status dot centred beneath it. That dot is `working` amber rather than `blocked` red on purpose:
// `BoringHerdBar.icns` already leads with red for its own top ledger row, and the two apps' icons sitting
// side by side in a Dock or Login Items list should read as two distinct marks, not as one icon repeated.
//
// One dot, not a row of three like `BoringHerdBar.icns`: HerdNotch's whole product is the *one* pill that
// summarises everything else, and a second glyph inside that pill would contradict the thing the icon is
// depicting.

import AppKit
import Foundation

// MARK: - Tokens

/// The panel's `surface`, `#16171A` — identical to `make-icon.swift`'s own token, since both apps' panels
/// share `HerdPalette`.
let surface = NSColor(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1)

/// The panel's `working`, `#F2A65A`. The peek dot's colour — see the file-level comment for why amber
/// rather than `blocked` red.
let working = NSColor(red: 0xF2 / 255, green: 0xA6 / 255, blue: 0x5A / 255, alpha: 1)

// MARK: - Geometry

/// Fraction of the canvas left empty around the rounded square, per Apple's macOS icon grid — identical to
/// `make-icon.swift`'s own token, so both apps' icons sit at the same optical size in a shared list.
let marginFraction: CGFloat = 100.0 / 1024.0

/// Corner radius as a fraction of the plate's side — identical to `make-icon.swift`'s own token.
let cornerFraction: CGFloat = 185.0 / 824.0

// MARK: - Drawing

/// Renders the icon at one pixel size.
///
/// Every length is derived from the plate's side rather than from the canvas, matching `make-icon.swift`'s
/// own `render(pixels:)` so the drawing is the same shape at every declared size and only the rounding
/// differs.
///
/// - Parameter pixels: Width and height in pixels. Always square.
/// - Returns: PNG data, or `nil` if the bitmap could not be made.
func render(pixels: Int) -> Data? {
    let side = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let margin = (side * marginFraction).rounded()
    let plate = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let plateSide = plate.width

    NSBezierPath(roundedRect: plate, xRadius: plateSide * cornerFraction, yRadius: plateSide * cornerFraction)
        .addClip()
    surface.setFill()
    plate.fill()

    // A faint inner rim, so the plate has an edge on a dark desktop — identical to `make-icon.swift`'s own
    // rim, skipped below 32 px for the same "a sub-pixel stroke only muddies the corners" reason.
    if pixels >= 32 {
        let rim = NSBezierPath(
            roundedRect: plate.insetBy(dx: 0.5, dy: 0.5),
            xRadius: plateSide * cornerFraction,
            yRadius: plateSide * cornerFraction
        )
        rim.lineWidth = max(1, plateSide / 256)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        rim.stroke()
    }

    // The notch: flat top (coincident with the plate's own flat top edge, away from its rounded corners),
    // rounded bottom-only corners, cut straight into the plate — the actual silhouette of the hardware
    // this app hangs its panel from, not a stand-in shape for it.
    let notchWidth = plateSide * 0.34
    let notchHeight = plateSide * 0.16
    let notchRadius = notchHeight * 0.55
    let notchRect = NSRect(
        x: plate.midX - notchWidth / 2,
        y: plate.maxY - notchHeight,
        width: notchWidth,
        height: notchHeight
    )
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: notchRect.minX, y: notchRect.maxY))
    notch.line(to: NSPoint(x: notchRect.maxX, y: notchRect.maxY))
    notch.line(to: NSPoint(x: notchRect.maxX, y: notchRect.minY + notchRadius))
    notch.appendArc(
        withCenter: NSPoint(x: notchRect.maxX - notchRadius, y: notchRect.minY + notchRadius),
        radius: notchRadius,
        startAngle: 0,
        endAngle: -90,
        clockwise: true
    )
    notch.line(to: NSPoint(x: notchRect.minX + notchRadius, y: notchRect.minY))
    notch.appendArc(
        withCenter: NSPoint(x: notchRect.minX + notchRadius, y: notchRect.minY + notchRadius),
        radius: notchRadius,
        startAngle: -90,
        endAngle: -180,
        clockwise: true
    )
    notch.close()
    NSColor.black.setFill()
    notch.fill()

    // The one peek dot, centred beneath the notch — `working` amber, with a soft glow behind it so it
    // reads as "lit" rather than as a flat sticker, the same "the dot is doing something" cue the panel's
    // own status dots carry.
    let dotDiameter = plateSide * 0.22
    let dotCenter = NSPoint(x: plate.midX, y: plate.midY - plateSide * 0.06)
    let dotRect = NSRect(
        x: dotCenter.x - dotDiameter / 2,
        y: dotCenter.y - dotDiameter / 2,
        width: dotDiameter,
        height: dotDiameter
    )
    if pixels >= 32 {
        let shadow = NSShadow()
        shadow.shadowColor = working.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = plateSide * 0.09
        shadow.shadowOffset = .zero
        shadow.set()
    }
    working.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
    NSShadow().set()

    NSGraphicsContext.current?.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit

/// The ten entries `iconutil` expects, as (file name, pixel size) — identical to `make-icon.swift`'s own
/// `variants` table.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("HerdNotch.iconset")
let icns = here.appendingPathComponent("HerdNotch.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, pixels) in variants {
    guard let data = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed: \(convert.terminationStatus)\n".utf8))
    exit(1)
}

// The iconset is an intermediate — identical to `make-icon.swift`'s own reasoning for removing it.
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
