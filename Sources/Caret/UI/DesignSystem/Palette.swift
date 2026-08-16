import AppKit
import SwiftUI

/// Caret's colours.
///
/// Warm rather than clinical: the greys all carry a little yellow, so nothing
/// reads as the blue-grey of a developer tool. Depth comes from surfaces sitting
/// on surfaces, not from borders — there is exactly one hairline in the whole
/// app and it is barely there.
///
/// Every colour is a dynamic `NSColor`, so light and dark are two deliberate
/// palettes rather than one palette and an inversion, and the system switches
/// between them at the moment it should — including under Increase Contrast.
public enum Palette {

    // MARK: - Surfaces

    /// The bottom-most layer. Warm off-white by day, warm near-black by night —
    /// never `#FFF` or `#000`, both of which glare.
    public static let canvas = dynamic(light: 0xFA_F9F7, dark: 0x1B_1A18)

    /// Cards, rows and panels: one step forward from the canvas.
    public static let surface = dynamic(light: 0xFF_FFFF, dark: 0x24_2220)

    /// Inset wells — list backgrounds, field interiors. One step *back*.
    public static let well = dynamic(light: 0xF1_EFEA, dark: 0x1F_1E1B)

    /// The wash under a row the pointer is over. Deliberately faint.
    public static let hover = dynamic(light: 0x2E_2C29, dark: 0xED_EAE4)

    // MARK: - Text

    public static let text = dynamic(light: 0x2C_2A27, dark: 0xEE_EBE5)
    public static let secondaryText = dynamic(light: 0x6B_6760, dark: 0xA6_A199)
    public static let tertiaryText = dynamic(light: 0x99_948B, dark: 0x76_716A)

    // MARK: - Accent

    /// A muted sage. Warm enough to sit beside the neutrals without arguing, far
    /// enough from Claude's orange to be its own thing, and calm enough that a
    /// correction landing never feels like an alert.
    public static let accent = dynamic(light: 0x5C_7360, dark: 0x8F_A891)

    /// For a filled accent surface — a touch deeper so white text holds up.
    public static let accentSolid = dynamic(light: 0x53_6A57, dark: 0x6E_8871)

    /// The faintest possible accent wash, for selected rows and badges.
    public static let accentWash = dynamicAlpha(
        light: 0x5C_7360, lightAlpha: 0.10,
        dark: 0x8F_A891, darkAlpha: 0.16
    )

    // MARK: - Lines and shadow

    /// The one hairline. Used where a gap alone would be ambiguous, nowhere else.
    public static let hairline = dynamicAlpha(
        light: 0x2C_2A27, lightAlpha: 0.08,
        dark: 0xEE_EBE5, darkAlpha: 0.09
    )

    /// Card shadow. Barely visible by design: it is there to lift an edge, not
    /// to draw one.
    public static let shadow = dynamicAlpha(
        light: 0x2C_2A27, lightAlpha: 0.10,
        dark: 0x00_0000, darkAlpha: 0.34
    )

    /// Reverting a correction, and nothing else. A muted clay, warm like the
    /// rest, well short of a warning red.
    public static let reverted = dynamic(light: 0xA9_6A56, dark: 0xC4_8B77)

    // MARK: - Construction

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }

    private static func dynamicAlpha(
        light: Int, lightAlpha: Double,
        dark: Int, darkAlpha: Double
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(rgb: dark, alpha: darkAlpha)
                : NSColor(rgb: light, alpha: lightAlpha)
        })
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones. Asking by name covers
    /// the high-contrast variants too, which a plain `== .darkAqua` misses.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    /// From `0xRRGGBB`. Colours are written as hex because that is how they were
    /// chosen, and translating them into floating-point triples in the source
    /// only makes them harder to adjust.
    convenience init(rgb: Int, alpha: Double = 1) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
