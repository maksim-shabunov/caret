#!/usr/bin/env swift
// Draws Caret's app icon and writes Resources/Caret.icns.
//
// The mark is drawn rather than kept as an image file so it can never drift out
// of step with the one in the About pane, and so the whole thing stays legible
// at 16pt. Run it from the project root:
//
//     swift Tools/MakeIcon.swift
//
// It only needs running when the mark itself changes; the .icns it produces is
// checked in alongside everything else.

import AppKit
import Foundation

// MARK: - Colours

/// The same warm palette the interface uses. Written out here rather than
/// imported, because this script has no business linking the app.
func colour(_ rgb: Int) -> NSColor {
    NSColor(
        srgbRed: Double((rgb >> 16) & 0xFF) / 255,
        green: Double((rgb >> 8) & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255,
        alpha: 1
    )
}

let backgroundTop = colour(0xFDFCFA)
let backgroundBottom = colour(0xEFECE5)
let markColour = colour(0x5C7360)

// MARK: - Drawing

/// One square icon at the given pixel size.
///
/// Everything is expressed as a fraction of `size`, so the 16pt icon and the
/// 1024pt icon are the same drawing rather than two that merely resemble one
/// another.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("could not allocate a bitmap at \(size)pt") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icons sit inside their canvas rather than filling it.
    let inset = side * 0.0977
    let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * 0.2237

    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A gradient this shallow reads as paper catching the light, not as a
    // gradient. That is the point.
    NSGradient(starting: backgroundTop, ending: backgroundBottom)?
        .draw(in: squircle, angle: -90)

    // The mark: a text insertion point, serifs and all.
    let markHeight = plate.height * 0.50
    let stem = markHeight * 0.088
    let serif = markHeight * 0.40
    let centre = NSPoint(x: plate.midX, y: plate.midY)
    let bottom = centre.y - markHeight / 2

    markColour.setFill()

    func bar(_ rect: NSRect) {
        NSBezierPath(roundedRect: rect, xRadius: stem / 2, yRadius: stem / 2).fill()
    }

    bar(NSRect(x: centre.x - stem / 2, y: bottom, width: stem, height: markHeight))
    for y in [bottom, bottom + markHeight - stem] {
        bar(NSRect(x: centre.x - serif / 2, y: y, width: serif, height: stem))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Writing the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Caret.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The sizes `iconutil` expects, each at 1× and 2×.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: points * scale)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(points)x\(points)\(suffix).png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let icns = root.appendingPathComponent("Resources/Caret.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote \(icns.path)")
