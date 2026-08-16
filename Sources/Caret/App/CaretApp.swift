import AppKit
import CaretCore
import SwiftUI

@main
struct CaretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var app: AppEnvironment { .shared }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(app)
        } label: {
            // The icon carries the state and nothing else: solid when Caret is
            // watching, faded when it is not. No badge, no colour, no count.
            Image(systemName: "character.cursor.ibeam")
                .opacity(app.preferences.isEnabled && app.permissions.isTrusted ? 1 : 0.45)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow()
                .environment(app)
        }
        // The real app menu, on screen whenever Caret is frontmost.
        .commands {
            // Caret makes no documents and no windows on demand, so every
            // entry the File menu would offer is one that does nothing.
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About Caret") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                PauseCommands(app: app)
            }

            CommandGroup(replacing: .help) {
                Button("Caret Setup…") {
                    app.showWelcome()
                }
            }
        }
    }
}

/// Pausing lives in the menu rather than the panel: it is a thing you do
/// occasionally and deliberately, not a switch you want under your thumb.
private struct PauseCommands: View {
    let app: AppEnvironment

    var body: some View {
        if let until = app.preferences.pausedUntil, until > Date() {
            Button("Resume Correcting") {
                app.preferences.resume()
                app.synchronise()
            }
        } else {
            Menu("Pause Correcting") {
                pause("For 15 Minutes", 15 * 60)
                pause("For an Hour", 60 * 60)
                pause("Until Tomorrow", 12 * 60 * 60)
            }
            .disabled(!app.preferences.isEnabled)
        }
    }

    private func pause(_ title: String, _ interval: TimeInterval) -> some View {
        Button(title) {
            app.preferences.pause(for: interval)
            app.synchronise()
        }
    }
}
