import AppKit
import CaretCore
import Observation
import SwiftUI

/// Everything the interface needs, assembled once.
///
/// Held by the app and handed down through the environment, so the menu panel,
/// the settings window and the welcome window all read the same objects rather
/// than each building their own.
@MainActor
@Observable
public final class AppEnvironment {

    /// One per process. The app delegate needs to reach this before any view
    /// exists, so it cannot live in `@State` alone.
    public static let shared = AppEnvironment()

    public let preferences: Preferences
    public let history: HistoryStore
    public let permissions = Permissions()
    public let controller: CorrectionController

    @ObservationIgnored private let hud = CorrectionHUD()
    @ObservationIgnored private let welcome = WelcomeWindowController()

    public init() {
        let preferences = Preferences()
        self.preferences = preferences
        history = HistoryStore(persists: preferences.keepHistoryOnDisk)
        controller = CorrectionController(preferences: preferences, history: history)

        controller.onCorrection = { [weak self] proposal in
            guard let self, self.preferences.showHUD else { return }
            self.hud.show(proposal)
        }

        permissions.onChange = { [weak self] _ in
            self?.synchronise()
        }
    }

    // MARK: - Starting and stopping

    /// Runs once, at launch.
    ///
    /// Caret has to start working the moment it is running, not the first time
    /// the menu is opened — a correction utility that waits to be looked at is
    /// no use at all.
    public func launch() {
        applyDockVisibility()
        synchronise()
        permissions.beginWatching()

        // First run, or the grant has been taken away. Either way there is
        // nothing Caret can do until it is asked for.
        if !permissions.isTrusted {
            showWelcome()
        }
    }

    public func showWelcome() {
        welcome.show(environment: self)
    }

    /// Puts Caret in the Dock, or takes it out.
    ///
    /// Called at launch, whenever the setting changes, and whenever a window
    /// opens or closes. That last one is the reason this is not a single line:
    /// with the Dock icon switched off, a window still needs an icon and a menu
    /// bar for as long as it is open, or Settings floats there belonging to
    /// nothing. So the policy is raised for the window and lowered again after.
    public func applyDockVisibility() {
        if preferences.showInDock {
            NSApp.setActivationPolicy(.regular)
            return
        }

        // Panels do not count: the menu bar panel and the HUD are not windows in
        // the sense that matters here.
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !(window is NSPanel)
        }
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }

    /// Brings the correction engine up if it is wanted and allowed.
    ///
    /// Safe to call as often as anything likes: it does nothing when the answer
    /// has not changed. Which is why every place that could change the answer
    /// simply calls it again.
    public func synchronise() {
        permissions.refresh()

        if preferences.isEnabled, permissions.isTrusted {
            controller.start()
        } else {
            // Covers the grant being withdrawn as well as the switch being
            // turned off. Either way, stop rather than sit there looking busy.
            controller.stop()
        }

        controller.preferencesChanged()
        LoginItem.set(preferences.launchAtLogin)
    }

    /// The one-line summary shown at the top of the menu panel.
    public var statusSummary: String {
        if !permissions.isTrusted { return "Waiting for permission" }
        if !preferences.isEnabled { return "Off" }
        if let until = preferences.pausedUntil, until > Date() {
            return "Paused until \(Self.time.string(from: until))"
        }
        // The tap can be refused or taken away while every other sign says
        // Caret is working. Saying so is the least it can do — a utility that
        // claims to be watching when it is deaf is worse than one that admits it.
        if !controller.isMonitoring { return "Not watching — check permission" }
        let count = controller.layouts.filter(preferences.isWatching).count
        return count == 1 ? "Watching 1 layout" : "Watching \(count) layouts"
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
