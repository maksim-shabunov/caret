import CaretCore
import SwiftUI

struct GeneralPane: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var preferences = app.preferences

        Pane {
            SettingsGroup {
                SettingRow(
                    "Correct layout mistakes",
                    explanation: "Watch what you type and fix words typed on the wrong keyboard layout."
                ) {
                    Toggle("", isOn: $preferences.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.isEnabled) { app.synchronise() }
                }

                Hairline()

                SettingRow(
                    "Show a note when a word changes",
                    explanation: "A small line at the bottom of the screen, reminding you how to undo. It never takes focus."
                ) {
                    Toggle("", isOn: $preferences.showHUD)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                }

                Hairline()

                SettingRow(
                    "Show in the Dock",
                    explanation: "Off leaves the menu bar as the only way in. The icon still comes back while a window is open."
                ) {
                    Toggle("", isOn: $preferences.showInDock)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.showInDock) { app.applyDockVisibility() }
                }

                Hairline()

                SettingRow(
                    "Open at login",
                    explanation: "Caret is only useful when it is already running."
                ) {
                    Toggle("", isOn: $preferences.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.launchAtLogin) {
                            // The system can refuse — the user may have the item
                            // switched off in System Settings. Show the truth
                            // rather than what was asked for.
                            LoginItem.set(preferences.launchAtLogin)
                            preferences.launchAtLogin = LoginItem.isEnabled
                        }
                }
            }

            SettingsGroup("Care") {
                SettingRow(
                    "Shortest word to correct",
                    explanation: "Short words carry too little evidence to judge safely. Three is a good floor; raise it if Caret is ever too eager."
                ) {
                    Stepper(
                        value: $preferences.minimumWordLength,
                        in: 2...8
                    ) {
                        Text("\(preferences.minimumWordLength) letters")
                            .font(Typography.body)
                            .foregroundStyle(Palette.text)
                            .monospacedDigit()
                    }
                    .onChange(of: preferences.minimumWordLength) { app.controller.preferencesChanged() }
                }

                Hairline()

                SettingRow(
                    "Correct slang and typos",
                    explanation: "Fixes words no dictionary carries — slang, shortened forms, names, misspellings — by judging whether the letters look like the language they would belong to."
                ) {
                    Toggle("", isOn: $preferences.correctsUnknownWords)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.correctsUnknownWords) {
                            app.controller.preferencesChanged()
                        }
                }

                Hairline()

                // The explanation follows the selection, so the difference
                // between the three is visible before committing to one.
                SettingRow(
                    "How readily",
                    explanation: preferences.sensitivity.explanation
                ) {
                    Picker("", selection: $preferences.sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: preferences.sensitivity) {
                        app.controller.preferencesChanged()
                    }
                }
                .disabled(!preferences.correctsUnknownWords)
                .opacity(preferences.correctsUnknownWords ? 1 : 0.4)

                Hairline()

                SettingRow(
                    "Read the sentence around a word",
                    explanation: "Remembers the last thirty characters typed, so a single letter can be fixed by the alphabet of the text it lands in — a lone “z” inside a Russian line becoming “я”. Forgotten when you switch app or stop typing for a minute, and never written to disk."
                ) {
                    Toggle("", isOn: $preferences.usesSurroundingText)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.usesSurroundingText) {
                            app.controller.preferencesChanged()
                        }
                }

                Hairline()

                SettingRow(
                    "Let ⌘Z undo a correction",
                    explanation: "For five seconds after Caret changes a word, ⌘Z puts it back. After that ⌘Z belongs to the app again."
                ) {
                    Toggle("", isOn: $preferences.interceptCommandZ)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Palette.accent)
                        .onChange(of: preferences.interceptCommandZ) {
                            app.controller.preferencesChanged()
                        }
                }
            }

            if !app.permissions.isTrusted {
                permissionCard
            }
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Space.normal) {
            Text("Accessibility access is switched off")
                .font(Typography.control)
                .foregroundStyle(Palette.text)
            Text("Caret cannot see what you type or replace it without this, so nothing will happen until it is granted.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // The one genuinely confusing case, and it happens after every
            // update of a downloaded build. macOS remembers the permission
            // against the app's signature; a downloaded Caret is signed ad hoc,
            // which means signed by its own contents, so a new version is a new
            // signature. The old entry stays in the list, still ticked, and
            // grants nothing. There is no way to detect that from inside the
            // process — `AXIsProcessTrusted` simply answers no — so the way out
            // is written down instead.
            Text("If Caret is already in that list, remove it with − and add it again. Updating changes the app's signature and macOS keeps the old entry, still ticked, granting nothing.")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                app.permissions.openSettings()
            }
            .buttonStyle(.accent)
        }
        .padding(Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
