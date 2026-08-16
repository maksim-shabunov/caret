import CaretCore
import SwiftUI

struct ShortcutsPane: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences

        Pane {
            SettingsGroup {
                SettingRow(
                    "Convert now",
                    explanation: "Converts the selected text, or the word you are in the middle of. Press it again to try the next layout."
                ) {
                    ShortcutRecorder(
                        shortcut: $preferences.manualShortcut,
                        fallback: .defaultManual
                    )
                    .onChange(of: preferences.manualShortcut) { app.controller.preferencesChanged() }
                }

                Hairline()

                SettingRow(
                    "Undo the last correction",
                    explanation: "Works long after ⌘Z has gone back to the app, for a correction you only notice later."
                ) {
                    ShortcutRecorder(
                        shortcut: $preferences.revertShortcut,
                        fallback: .defaultRevert
                    )
                    .onChange(of: preferences.revertShortcut) { app.controller.preferencesChanged() }
                }
            }

            if conflict {
                Text("Both shortcuts are set to the same keys. Caret will convert rather than undo.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.reverted)
                    .padding(.leading, Space.tight)
            }

            VStack(alignment: .leading, spacing: Space.snug) {
                SectionHeading("How it works")
                Text("Caret records the physical key you pressed, not the letter it produced — so a shortcut keeps meaning the same key however many layouts you switch between.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.tight)
            }
        }
    }

    private var conflict: Bool {
        app.preferences.manualShortcut == app.preferences.revertShortcut
    }
}
