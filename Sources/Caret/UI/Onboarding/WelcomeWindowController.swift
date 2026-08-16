import AppKit
import SwiftUI

/// Holds the welcome window.
///
/// An `NSWindow` rather than a SwiftUI `Window` scene, because this one needs
/// opening from places that have no view to ask — at launch, before anything is
/// on screen, and from the menu panel. A scene can only be opened by a view that
/// happens to be alive, which is exactly the wrong constraint for a window whose
/// whole job is to appear when nothing else has.
@MainActor
final class WelcomeWindowController {

    private var window: NSWindow?

    func show(environment: AppEnvironment) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: WelcomeWindow(onDone: { [weak self] in self?.close() })
                .environment(environment)
        )

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Caret"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        // The window's own background shows through behind the transparent
        // title bar, so it has to match the canvas the content is drawn on.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(rgb: 0x1B_1A18) : NSColor(rgb: 0xFA_F9F7)
        }
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
