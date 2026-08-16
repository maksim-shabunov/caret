#!/usr/bin/env swift
//
// Renders the images the README uses.
//
//   swift Tools/MakeDemo.swift
//
// Two of them: an animated GIF of a word being corrected as it is typed, and a
// still banner of the same thing for anywhere a GIF will not play.
//
// Drawn rather than screen-recorded, and the reason is worth stating: recording
// the real thing needs Accessibility permission, and permission is granted to a
// signature, so the recording would have to be redone for every release. This
// renders from the same palette the app uses, so it cannot drift from it either.
// What it shows is exactly what Caret does — the frames below are the keystrokes
// in order, and the correction lands on the space, which is when Caret acts.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The app's own palette, light appearance. See UI/DesignSystem/Palette.swift.
let canvas = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF7 / 255, alpha: 1)
let surface = NSColor.white
let ink = NSColor(srgbRed: 0x2C / 255, green: 0x2A / 255, blue: 0x27 / 255, alpha: 1)
let secondary = NSColor(srgbRed: 0x6B / 255, green: 0x67 / 255, blue: 0x60 / 255, alpha: 1)
let tertiary = NSColor(srgbRed: 0x99 / 255, green: 0x94 / 255, blue: 0x8B / 255, alpha: 1)
let accent = NSColor(srgbRed: 0x5C / 255, green: 0x73 / 255, blue: 0x60 / 255, alpha: 1)
let hairline = NSColor(srgbRed: 0x2C / 255, green: 0x2A / 255, blue: 0x27 / 255, alpha: 0.10)

let scale: CGFloat = 2
let width: CGFloat = 720
let height: CGFloat = 260

/// One moment in the demo: what is on screen, and for how long.
struct Frame {
    let typed: String
    /// Shown under the field once the correction has landed.
    let corrected: Bool
    let seconds: Double
    var caret = true
}

/// `ghbdtn` typed letter by letter, then the space that triggers the fix.
func script() -> [Frame] {
    var frames: [Frame] = [Frame(typed: "", corrected: false, seconds: 0.9)]
    let typed = "ghbdtn"
    for end in 1...typed.count {
        frames.append(Frame(
            typed: String(typed.prefix(end)),
            corrected: false,
            seconds: 0.16
        ))
    }
    // The pause before the space, which is where the eye lands.
    frames.append(Frame(typed: typed, corrected: false, seconds: 0.75))
    // Caret acts on the space.
    frames.append(Frame(typed: "привет ", corrected: true, seconds: 2.6))
    return frames
}

func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func mono(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

func draw(_ frame: Frame, showCaret: Bool) -> CGImage {
    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)
    let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    canvas.setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()

    // ---- the text field
    let field = CGRect(x: 56, y: 96, width: width - 112, height: 84)
    let rounded = NSBezierPath(roundedRect: field, xRadius: 14, yRadius: 14)
    surface.setFill()
    rounded.fill()
    hairline.setStroke()
    rounded.lineWidth = 1
    rounded.stroke()

    // ---- what has been typed
    let body = mono(30)
    let text = frame.typed as NSString
    let colour = frame.corrected ? ink : secondary
    let attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: colour]
    let size = text.size(withAttributes: attributes)
    let textOrigin = CGPoint(x: field.minX + 28, y: field.midY - size.height / 2)
    text.draw(at: textOrigin, withAttributes: attributes)

    // ---- the insertion point
    if showCaret {
        accent.withAlphaComponent(0.9).setFill()
        CGRect(x: textOrigin.x + size.width + 2, y: field.midY - 18, width: 2.5, height: 36).fill()
    }

    // ---- the label above the field
    let label = (frame.corrected ? "Corrected" : "Typing on the English layout") as NSString
    label.draw(
        at: CGPoint(x: field.minX + 2, y: field.maxY + 18),
        withAttributes: [
            .font: font(15, weight: .medium),
            .foregroundColor: frame.corrected ? accent : tertiary,
        ]
    )

    // ---- the note beneath, once it has happened
    if frame.corrected {
        let note = "ghbdtn  →  привет      ⌘Z to undo" as NSString
        note.draw(
            at: CGPoint(x: field.minX + 2, y: field.minY - 40),
            withAttributes: [.font: font(15), .foregroundColor: tertiary]
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

// ---------------------------------------------------------------- the GIF

func writeGIF(to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, 0, nil
    )!
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)

    for frame in script() {
        // The caret blinks only while the field is idle; during typing it stays
        // put, which is what a real one does.
        let blinks = frame.seconds > 0.5
        if blinks {
            let halves = Int((frame.seconds / 0.5).rounded())
            for half in 0..<max(halves, 1) {
                let image = draw(frame, showCaret: half % 2 == 0)
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.5],
                ] as CFDictionary)
            }
        } else {
            let image = draw(frame, showCaret: true)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: frame.seconds,
                ],
            ] as CFDictionary)
        }
    }
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not write the gif\n".utf8))
        exit(1)
    }
}

// ---------------------------------------------------------------- the banner

func writeBanner(to url: URL) {
    let image = draw(
        Frame(typed: "привет ", corrected: true, seconds: 0),
        showCaret: true
    )
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}

let images = URL(fileURLWithPath: "docs/images")
try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

writeGIF(to: images.appendingPathComponent("demo.gif"))
writeBanner(to: images.appendingPathComponent("demo.png"))
print("wrote docs/images/demo.gif and docs/images/demo.png")
