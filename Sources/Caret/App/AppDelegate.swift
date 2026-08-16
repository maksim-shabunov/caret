import AppKit
import SwiftUI

/// The AppKit half.
///
/// SwiftUI handles the scenes; this handles what it cannot express — the Dock
/// icon and its menu, what a click on that icon does, and what happens when the
/// last window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start correcting immediately. Waiting for a view to appear would mean
        // Caret did nothing until the menu was opened. This also settles the
        // Dock icon, before anything has had a chance to be drawn.
        AppEnvironment.shared.launch()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowsChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowsChanged),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    /// Quitting is deliberate — closing the Settings window is not.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon with nothing open.
    ///
    /// Caret has no document and no main window, so the default behaviour is to
    /// activate and show nothing at all, which reads as a broken icon. Settings
    /// is the only real window it has, so that is what a click means.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { openSettings() }
        return true
    }

    @objc private func windowsChanged() {
        // `willClose` arrives before the window is actually gone, so the count
        // is taken on the next turn of the loop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppEnvironment.shared.applyDockVisibility()
            }
        }
    }

    // MARK: - Dock menu

    /// The same few things the menu bar panel offers, for the other icon.
    ///
    /// macOS adds Options, Show in Finder and Quit underneath on its own, so
    /// this only has to cover what is specific to Caret.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let app = AppEnvironment.shared
        let menu = NSMenu()

        menu.addItem(
            item(app.preferences.isEnabled ? "Turn Caret Off" : "Turn Caret On", #selector(toggleEnabled))
        )

        if app.preferences.isEnabled {
            let paused = (app.preferences.pausedUntil ?? .distantPast) > Date()
            if paused {
                menu.addItem(item("Resume Correcting", #selector(resumeCorrecting)))
            } else {
                let submenu = NSMenu()
                submenu.addItem(item("For 15 Minutes", #selector(pauseShort)))
                submenu.addItem(item("For an Hour", #selector(pauseHour)))
                submenu.addItem(item("Until Tomorrow", #selector(pauseDay)))

                let pause = NSMenuItem(title: "Pause Correcting", action: nil, keyEquivalent: "")
                pause.submenu = submenu
                menu.addItem(pause)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        let app = AppEnvironment.shared
        app.preferences.isEnabled.toggle()
        app.synchronise()
    }

    @objc private func resumeCorrecting() {
        AppEnvironment.shared.preferences.resume()
        AppEnvironment.shared.synchronise()
    }

    @objc private func pauseShort() { pause(15 * 60) }
    @objc private func pauseHour() { pause(60 * 60) }
    @objc private func pauseDay() { pause(12 * 60 * 60) }

    private func pause(_ interval: TimeInterval) {
        AppEnvironment.shared.preferences.pause(for: interval)
        AppEnvironment.shared.synchronise()
    }

    @objc private func showSettings() {
        openSettings()
    }

    /// SwiftUI owns the Settings scene and exposes no way to open it from
    /// AppKit, so this goes through the responder chain the way the menu item
    /// itself does. If the action ever stops existing, bringing an open window
    /// forward is at least not nothing.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }

        let window = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
        window?.makeKeyAndOrderFront(nil)
    }
}
