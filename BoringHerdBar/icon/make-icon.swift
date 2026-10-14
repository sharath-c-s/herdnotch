// Generates BoringHerdBar.icns from code, with no Xcode and no asset catalog.
//
// Why this exists as a script rather than an `Assets.xcassets`: compiling an asset catalog needs
// `actool`, which ships with Xcode and is a stub in Command Line Tools, and the whole point of this
// project's build is that only Command Line Tools are required. `iconutil` *is* in Command Line Tools,
// so an `.iconset` directory of PNGs plus `iconutil -c icns` gets there with no Xcode at all.
//
// The output is committed rather than generated during `build.sh`. Regenerating on every build would
// make an ordinary build depend on AppKit rendering and on `iconutil`, for artwork that changes about
// never; and a committed `.icns` means `build.sh` only has to copy a file. Run this by hand after
// editing the drawing, and commit the result:
//
//     swift icon/make-icon.swift && ./build.sh
//
// This file may import AppKit freely. It is a build tool, not part of any app target, so the
// "SwiftUI and HerdKit only" rule that governs `HerdPanelUI` does not reach it.
//
// MARK: - What the icon is, and the two drawings that were rejected first
//
// The icon is **the ledger**: three rows, each a status dot in a gutter beside a name bar, on the
// panel's own near-black plate. That is a literal miniature of the one surface this app has, so the
// icon and the product teach the same thing, and it carries the palette's hierarchy in the order the
// user reads it: red waiting, amber working, blue idle.
//
// It is drawn from rectangles and ovals rather than from a symbol, and that is the second attempt.
//
// **Rejected: `point.3.connected.trianglepath.dotted`**, the status item's own SF Symbol, on the
// reasoning that the icon and the menu bar should match. It failed at the size that matters most. The
// symbol is three rings joined by *dotted* connectors, and at 16 px, which is what Login Items and a
// Finder list column show, the dots fall below one pixel and the rings fill in: the result was a dark
// blob with two smudges, recognisable as nothing. Detail that cannot survive a 64:1 downsample is
// detail that only exists in the mockup.
//
// **Rejected: tinting a symbol with `NSImage(size:flipped:)` plus `.destinationIn`.** The usual trick,
// and it left a faint rectangle at the tinted image's bounds in the rendered output, because the
// drawing handler re-runs at the destination scale and the fill's antialiased edge survives the
// composite. Fixable by rendering the tint into its own bitmap rep first, but by then the symbol had
// already been rejected on legibility, and shapes need no tinting at all.

import AppKit
import Foundation

// MARK: - Tokens

/// The panel's `surface`, `#16171A`.
///
/// The same near-black the panel is, not a lighter "app icon" shade, because the two are seen within a
/// second of each other: the icon in Login Items or the Finder, the panel a click later.
let surface = NSColor(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1)

/// The panel's `textPrimary`, `#E8E9EC`. The name bar of a row that is doing or wanting something.
let namePrimary = NSColor(red: 0xE8 / 255, green: 0xE9 / 255, blue: 0xEC / 255, alpha: 1)

/// The panel's `textIdle`, `#969CA5`. The name bar of a quiet row.
let nameIdle = NSColor(red: 0x96 / 255, green: 0x9C / 255, blue: 0xA5 / 255, alpha: 1)

/// The panel's `blocked`, `#FF6B6B`.
let blocked = NSColor(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255, alpha: 1)

/// The panel's `working`, `#F2A65A`.
let working = NSColor(red: 0xF2 / 255, green: 0xA6 / 255, blue: 0x5A / 255, alpha: 1)

/// The panel's `idle`, `#5E8CB8`.
let idle = NSColor(red: 0x5E / 255, green: 0x8C / 255, blue: 0xB8 / 255, alpha: 1)

// MARK: - Geometry

/// Fraction of the canvas left empty around the rounded square, per Apple's macOS icon grid: the
/// artwork occupies the middle ~80% and the surrounding margin is what keeps a row of app icons
/// optically the same size. An icon drawn edge to edge reads as oversized beside every system app.
let marginFraction: CGFloat = 100.0 / 1024.0

/// Corner radius as a fraction of the plate's side. A true macOS squircle is a superellipse; the
/// visible difference from a rounded rect at these sizes is nil, and this keeps the script to one file.
let cornerFraction: CGFloat = 185.0 / 824.0

/// One ledger row: which colour its status dot takes, and how far its name bar runs across the plate.
///
/// The three bar lengths differ so the block reads as a list of names of different lengths rather than
/// as a barcode. Ordered as the panel orders them, most urgent first.
struct Row {
    /// Status dot colour.
    let dot: NSColor
    /// Name bar colour.
    let bar: NSColor
    /// Bar width as a fraction of the width available to bars.
    let extent: CGFloat
}

let rows = [
    Row(dot: blocked, bar: namePrimary, extent: 1.00),
    Row(dot: working, bar: namePrimary, extent: 0.72),
    Row(dot: idle, bar: nameIdle, extent: 0.86),
]

// MARK: - Drawing

/// Renders the icon at one pixel size.
///
/// Every length is derived from the plate's side rather than from the canvas, so the drawing is the same
/// shape at 16 px and 1024 px and only the rounding differs.
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

    // A faint inner rim, so the plate has an edge on a dark desktop where near-black on black would
    // dissolve. Skipped below 32 px, where a sub-pixel stroke only muddies the corners.
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

    // The ledger block, optically centred in the plate.
    //
    // At 16 px the three rows would land on about five pixels each and the dots would merge into their
    // bars, so the small sizes drop to **two** rows. Two rows still read as a list, still carry the red
    // that means "one of them needs you", and survive the downsample. This is the whole reason the icon
    // is drawn rather than scaled: the small sizes are allowed to be a different, simpler picture.
    let visible = pixels <= 32 ? Array(rows.prefix(2)) : rows

    let rowGap = plateSide * (visible.count == 2 ? 0.20 : 0.135)
    let dotDiameter = plateSide * (visible.count == 2 ? 0.19 : 0.145)
    let barHeight = dotDiameter * (visible.count == 2 ? 0.80 : 0.72)
    let gutter = dotDiameter * 0.75
    let leftInset = plateSide * 0.16

    let blockHeight = CGFloat(visible.count) * dotDiameter + CGFloat(visible.count - 1) * rowGap
    // Nudged up a hair from true centre: a block of rows with the heaviest at the top sits low
    // optically when it is mathematically centred.
    var y = plate.midY + blockHeight / 2 - dotDiameter + plateSide * 0.012

    let barStart = plate.minX + leftInset + dotDiameter + gutter
    let barSpan = plate.maxX - plateSide * 0.13 - barStart

    for row in visible {
        let dotRect = NSRect(
            x: plate.minX + leftInset,
            y: y,
            width: dotDiameter,
            height: dotDiameter
        )
        row.dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let barRect = NSRect(
            x: barStart,
            y: dotRect.midY - barHeight / 2,
            width: (barSpan * row.extent).rounded(),
            height: barHeight
        )
        row.bar.setFill()
        // Rounded caps at large sizes so the bars read as set text rather than as a chart; square below
        // 64 px, where a radius that small only softens the ends into grey.
        if pixels >= 64 {
            NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        } else {
            barRect.fill()
        }

        y -= dotDiameter + rowGap
    }

    NSGraphicsContext.current?.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit

/// The ten entries `iconutil` expects, as (file name, pixel size).
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
let iconset = here.appendingPathComponent("BoringHerdBar.iconset")
let icns = here.appendingPathComponent("BoringHerdBar.icns")

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

// The iconset is an intermediate. Leaving it behind would put ten PNGs next to the one file that
// matters and invite someone to edit those instead of this script.
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
