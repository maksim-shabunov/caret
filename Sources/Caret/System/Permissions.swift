import ApplicationServices
import AppKit
import Observation

/// Caret needs Accessibility permission and nothing else.
///
/// It is used for two things: watching keystrokes, and putting corrected text
/// back where the wrong text was. macOS grants it per signed binary, so the
/// build script signs with a stable identity — otherwise every rebuild would
/// look like a new app and ask again.
@MainActor
@Observable
public final class Permissions {

    public private(set) var isTrusted: Bool = AXIsProcessTrusted()

    /// Called when the answer changes. The grant can be given or taken away in
    /// System Settings at any moment, with no window of Caret's open to notice,
    /// so something has to be listening.
    @ObservationIgnored public var onChange: ((Bool) -> Void)?

    @ObservationIgnored private var timer: Timer?

    /// Whether an earlier version's grant has been left behind rather than
    /// carried over.
    ///
    /// This is the ad-hoc update, and it is worth detecting because it is the
    /// one failure that looks like nothing is wrong. macOS records the grant
    /// against the app's signature; a downloaded Caret is signed ad hoc, which
    /// means signed by its own contents, so every version signs differently. The
    /// old entry stays in the Accessibility list, still ticked, granting
    /// nothing — and `AXIsProcessTrusted` only ever answers no, with no way to
    /// ask why.
    ///
    /// So the question is asked of what Caret can see for itself: a version ran
    /// here before, this is a different one, and it does not have permission.
    /// Whether the earlier version *held* the grant is deliberately not part of
    /// it — recording that would have been the tidier test and would have missed
    /// every user upgrading from a version too old to have recorded anything,
    /// which on the day this shipped was all of them.
    ///
    /// Someone opening Caret for the first time has no previous version and is
    /// told nothing. Someone who relaunches without having granted permission
    /// yet is on the same version, and is also told nothing — they have not been
    /// to Settings at all, so there is no stale entry to explain.
    public var hasStaleGrant: Bool {
        guard !isTrusted, let previous else { return false }
        return previous != Self.currentVersion
    }

    private static let lastLaunchedVersion = "lastLaunchedVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The version that ran last, read once before this launch overwrites it.
    @ObservationIgnored private let previous: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        previous = defaults.string(forKey: Self.lastLaunchedVersion)
        defaults.set(Self.currentVersion, forKey: Self.lastLaunchedVersion)
    }

    /// Asks the system to show the standard permission prompt.
    ///
    /// The system only shows it once per app; afterwards this is a no-op and the
    /// user has to go to Settings, which is why `openSettings()` exists too.
    public func request() {
        // Spelled out rather than read from `kAXTrustedCheckOptionPrompt`, which
        // is a mutable global and so off limits under strict concurrency. The
        // key itself has been stable for the entire life of the API.
        let options = ["AXTrustedCheckOptionPrompt": true]
        isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        beginWatching()
    }

    public func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onChange?(trusted)
    }

    public func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
        beginWatching()
    }

    /// There is no notification when the grant changes, so poll gently. Once a
    /// second while waiting for it, once every ten once it has arrived — the
    /// grant can be withdrawn just as easily as it was given, and Caret should
    /// notice rather than sit there looking as though it still works.
    public func beginWatching() {
        stopWatching()
        let interval: TimeInterval = isTrusted ? 10 : 1
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.isTrusted
                self.refresh()
                // The polling rate belongs to the state, so re-arm on a change.
                if self.isTrusted != was { self.beginWatching() }
            }
        }
    }

    public func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}
