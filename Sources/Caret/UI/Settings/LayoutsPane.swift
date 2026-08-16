import CaretCore
import SwiftUI

/// Which layouts Caret is allowed to convert into, and in what order.
///
/// The list comes from the system, so it matches System Settings › Keyboard
/// exactly. Switching one off here does not disable it for typing — it only
/// tells Caret to stop offering it as an answer.
///
/// The order is the second half of the same question. Most of the time the words
/// themselves settle which layout was meant, but `]un` is `õun` in Estonian and
/// `ъгт` in Russian, and no amount of looking at the letters will say which. That
/// is what this order is for, and it is consulted last: evidence about the
/// sentence in front of the user always comes first.
struct LayoutsPane: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Pane {
            VStack(alignment: .leading, spacing: Space.snug) {
                SectionHeading("Languages, in order")
                Text("Caret compares what you typed against each of these, from the top down. When two of them could both be right, the one nearer the top wins — so keep the language you write most at the top. Turn one off if it keeps suggesting a language you do not write in.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.tight)
            }

            SettingsGroup {
                let ordered = app.preferences.ordered(app.controller.layouts)

                if ordered.isEmpty {
                    empty
                } else {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, layout in
                        if index > 0 { Hairline() }
                        row(for: layout, at: index, of: ordered.count)
                    }
                }
            }

            if app.controller.layouts.count < 2 {
                Text("Caret needs a second layout before it can compare anything. Add one in System Settings › Keyboard › Text Input.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.tight)
            }
        }
    }

    private func row(for layout: KeyboardLayout, at index: Int, of count: Int) -> some View {
        SettingRow(layout.localizedName, explanation: describe(layout)) {
            HStack(spacing: Space.hair) {
                move(layout, by: -1, enabled: index > 0)
                move(layout, by: 1, enabled: index < count - 1)

                Toggle("", isOn: Binding(
                    get: { app.preferences.isWatching(layout) },
                    set: {
                        app.preferences.setWatching($0, for: layout)
                        app.controller.preferencesChanged()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.accent)
                .padding(.leading, Space.snug)
            }
        }
    }

    /// One step up or down the list. Two small buttons rather than dragging: a
    /// list of three items is not worth learning a gesture for, and a button says
    /// what it does to a screen reader without any help.
    private func move(_ layout: KeyboardLayout, by offset: Int, enabled: Bool) -> some View {
        Button {
            app.preferences.movePriority(of: layout, by: offset, within: app.controller.layouts)
            app.controller.preferencesChanged()
        } label: {
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Palette.secondaryText : Palette.tertiaryText.opacity(0.35))
        .disabled(!enabled)
        .accessibilityLabel(
            offset < 0
                ? "Move \(layout.localizedName) up"
                : "Move \(layout.localizedName) down"
        )
        .help(offset < 0 ? "Prefer this layout over the one above" : "Prefer the layout below over this one")
    }

    /// The layout's own language, and whatever else is worth saying about it.
    ///
    /// A layout that is switched off keeps its place in the list, which would read
    /// as a contradiction — third in a queue nobody joins — so the row says so
    /// rather than leaving the two controls to argue with each other.
    private func describe(_ layout: KeyboardLayout) -> String {
        let language = Locale.current.localizedString(forLanguageCode: layout.primaryLanguage)
            ?? layout.primaryLanguage
        var notes = [language]
        if app.controller.activeLayout?.id == layout.id { notes.append("in use now") }
        if !app.preferences.isWatching(layout) { notes.append("not checked") }
        return notes.joined(separator: " · ")
    }

    private var empty: some View {
        Text("No keyboard layouts found.")
            .font(Typography.body)
            .foregroundStyle(Palette.secondaryText)
            .padding(Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
