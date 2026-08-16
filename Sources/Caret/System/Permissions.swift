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

    /// Whether permission was granted to an earlier version and has not carried
    /// over to this one.
    ///
    /// This is the ad-hoc update, and it is worth detecting because it is the
    /// one failure that looks like nothing is wrong. macOS records the grant
    /// against the app's signature; a downloaded Caret is signed ad hoc, which
    /// means signed by its own contents, so every version signs differently. The
    /// old entry stays in the Accessibility list, still ticked, granting
    /// nothing — and `AXIsProcessTrusted` just answers no, with no way to ask
    /// why. So the fact is remembered instead: a version that once held the
    /// grant, and a running version that does not, is that situation and no
    /// other. A first run has nothing recorded and says nothing.
    public var hasStaleGrant: Bool {
        guard !isTrusted, let granted = defaults.string(forKey: Self.lastTrustedVersion)
        else { return false }
        return granted != Self.currentVersion
    }

    private static let lastTrustedVersion = "lastTrustedVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if isTrusted { rememberGrant() }
    }

    private func rememberGrant() {
        defaults.set(Self.currentVersion, forKey: Self.lastTrustedVersion)
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
        if isTrusted { rememberGrant() }
        beginWatching()
    }

    public func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { rememberGrant() }
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
