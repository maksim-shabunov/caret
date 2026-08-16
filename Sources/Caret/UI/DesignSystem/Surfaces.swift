import SwiftUI

/// The building blocks every screen is made of.
///
/// Three shapes and nothing else: a card, a row inside it, and a heading above
/// it. Keeping the vocabulary this small is what makes the settings window and
/// the menu panel look like the same app rather than two.

// MARK: - Card

/// A raised surface. Depth comes from a very soft shadow rather than a border,
/// which is the whole difference between calm and technical.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: Palette.shadow, radius: 6, x: 0, y: 1)
            )
    }
}

// MARK: - Section heading

/// The small line above a group. Uppercase would shout; this does not.
public struct SectionHeading: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.section)
            .foregroundStyle(Palette.tertiaryText)
            .padding(.leading, Space.tight)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Setting row

/// One setting: a label, an optional explanation, and a control on the right.
///
/// The explanation sits under the label rather than beside it, so the control
/// column stays straight all the way down the pane however much any one setting
/// needs to say for itself.
public struct SettingRow<Control: View>: View {
    private let title: String
    private let explanation: String?
    private let control: Control

    public init(
        _ title: String,
        explanation: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.explanation = explanation
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.roomy) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title)
                    .font(Typography.control)
                    .foregroundStyle(Palette.text)
                if let explanation {
                    Text(explanation)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.snug)
            control
        }
        .padding(.vertical, Space.normal)
        .padding(.horizontal, Space.roomy)
    }
}

// MARK: - Hairline

/// The divider between rows in a card. Inset from both edges so the card's
/// corners stay round and the line never reads as a table border.
public struct Hairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, Space.roomy)
    }
}

// MARK: - Composition helper

public extension View {
    /// Stacks rows into a card with hairlines between them.
    func cardBackground() -> some View {
        Card { self }
    }
}
