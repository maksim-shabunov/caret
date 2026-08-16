import SwiftUI

/// Button styles.
///
/// macOS already draws excellent controls, so Caret leaves the ones that carry
/// weight — switches, popups, steppers — entirely alone and only restyles the
/// places where the system has no opinion: the quiet rows in the menu panel.

/// A borderless row that lifts under the pointer and settles when pressed.
/// Used for everything in the menu bar panel.
public struct QuietButtonStyle: ButtonStyle {
    @State private var isHovering = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.snug)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Palette.hover)
                    .opacity(configuration.isPressed ? 0.10 : (isHovering ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .onHover { isHovering = $0 }
            // No spring, no bounce. A wash appearing is enough.
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The one filled button in the app, for the single action a window is asking
/// for — granting permission, mostly.
public struct AccentButtonStyle: ButtonStyle {
    @State private var isHovering = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.control)
            .foregroundStyle(.white)
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(Palette.accentSolid)
                    .brightness(configuration.isPressed ? -0.04 : (isHovering ? 0.03 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

public extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// A short label on a soft accent wash. Used for the layout name on a
/// correction and nothing else, so it keeps its meaning.
public struct Badge: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Space.snug)
            .padding(.vertical, Space.hair)
            .background(
                Capsule(style: .continuous).fill(Palette.accentWash)
            )
    }
}
