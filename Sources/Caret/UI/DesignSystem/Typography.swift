import SwiftUI

/// Type and spacing.
///
/// The system face, used quietly. Two weights carry almost everything —
/// regular for prose, medium for the handful of things that genuinely lead —
/// and hierarchy comes from size and colour rather than from bold. There is no
/// semibold in the interface at all.
public enum Typography {

    /// The one line at the top of a settings pane or the menu panel.
    public static let title = Font.system(size: 15, weight: .medium)

    /// A group heading. Small, and carried by colour rather than weight.
    public static let section = Font.system(size: 11, weight: .medium)

    /// Ordinary interface text.
    public static let body = Font.system(size: 13)

    /// The label of a control that leads its row.
    public static let control = Font.system(size: 13, weight: .medium)

    /// The explanatory line under a setting.
    public static let caption = Font.system(size: 11)

    /// Corrected text in the history list. Monospaced digits keep the columns
    /// from shifting, but it is otherwise the reading face — this is language,
    /// not code.
    public static let word = Font.system(size: 12).monospacedDigit()

    /// Key combinations, where the fixed advance actually helps.
    public static let key = Font.system(size: 12, design: .monospaced)
}

/// The spacing scale. Everything in the interface is one of these, which is what
/// keeps the whitespace feeling deliberate rather than approximate.
public enum Space {
    /// 2 — inside a badge.
    public static let hair: CGFloat = 2
    /// 4 — between a label and the caption beneath it.
    public static let tight: CGFloat = 4
    /// 8 — between related controls.
    public static let snug: CGFloat = 8
    /// 12 — the standard gap inside a card.
    public static let normal: CGFloat = 12
    /// 16 — a card's own padding.
    public static let roomy: CGFloat = 16
    /// 24 — between groups.
    public static let section: CGFloat = 24
    /// 32 — a pane's outer margin.
    public static let margin: CGFloat = 32
}

/// Corner radii. Gentle throughout; nothing in Caret has a sharp corner.
public enum Radius {
    /// Badges and small wells.
    public static let small: CGFloat = 6
    /// Rows and fields.
    public static let medium: CGFloat = 8
    /// Cards.
    public static let large: CGFloat = 12
    /// The menu bar panel itself.
    public static let panel: CGFloat = 14
}
