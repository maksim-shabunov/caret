import Foundation
import Observation

/// Everything the user can change, persisted to `UserDefaults`.
@MainActor
@Observable
public final class Preferences {

    private enum Key {
        static let enabled = "enabled"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let showHUD = "showHUD"
        static let interceptCommandZ = "interceptCommandZ"
        static let minimumWordLength = "minimumWordLength"
        static let correctsUnknownWords = "correctsUnknownWords"
        static let sensitivity = "sensitivity"
        static let usesSurroundingText = "usesSurroundingText"
        static let disabledLayoutIDs = "disabledLayoutIDs"
        static let layoutPriority = "layoutPriority"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let manualShortcut = "manualShortcut"
        static let revertShortcut = "revertShortcut"
        static let keepHistoryOnDisk = "keepHistoryOnDisk"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Suppresses writes while the initialiser is populating values.
    @ObservationIgnored private var loaded = false

    public var isEnabled: Bool { didSet { write(isEnabled, Key.enabled) } }
    public var launchAtLogin: Bool { didSet { write(launchAtLogin, Key.launchAtLogin) } }

    /// Off hides the Dock icon and the app switcher entry, leaving the menu bar
    /// as the only way in. The Dock icon still appears while a window is open,
    /// because a window with no icon behind it behaves like an orphan.
    public var showInDock: Bool { didSet { write(showInDock, Key.showInDock) } }

    public var showHUD: Bool { didSet { write(showHUD, Key.showHUD) } }

    /// When on, ⌘Z within the undo window reverts Caret instead of reaching the
    /// app underneath. Off puts ⌘Z entirely back in the app's hands, leaving
    /// the dedicated revert shortcut as the only way back.
    public var interceptCommandZ: Bool { didSet { write(interceptCommandZ, Key.interceptCommandZ) } }

    /// Shorter words carry too little signal to judge safely.
    public var minimumWordLength: Int {
        didSet {
            minimumWordLength = min(max(minimumWordLength, 2), 8)
            write(minimumWordLength, Key.minimumWordLength)
        }
    }

    /// Whether Caret may act on words no dictionary recognises — slang, clipped
    /// forms, regional spellings and typos — by judging the shape of the letters
    /// instead. Off leaves only the dictionary rules, which is what Caret did
    /// before it could measure shape at all.
    public var correctsUnknownWords: Bool {
        didSet { write(correctsUnknownWords, Key.correctsUnknownWords) }
    }

    /// How readily to act on shape alone. Only consulted when
    /// `correctsUnknownWords` is on; the dictionary rules have no setting because
    /// a dictionary either recognises a word or it does not.
    public var sensitivity: Sensitivity {
        didSet { write(sensitivity.rawValue, Key.sensitivity) }
    }

    /// Whether Caret may keep the last thirty characters typed, to tell which
    /// alphabet a sentence is in. This is the only thing that can rescue a word
    /// of one or two letters — a lone `z` where `я` was meant — because nothing
    /// about the letter itself will ever say which was intended.
    ///
    /// Off means nothing is remembered between keystrokes at all.
    public var usesSurroundingText: Bool {
        didSet { write(usesSurroundingText, Key.usesSurroundingText) }
    }

    /// Layouts the user has switched off. Stored as the excluded set so a newly
    /// installed layout is watched by default.
    public var disabledLayoutIDs: Set<String> {
        didSet { write(Array(disabledLayoutIDs), Key.disabledLayoutIDs) }
    }

    /// The order layouts are considered in, best first. Empty until the user
    /// arranges them, which leaves the system's own order in place and leaves
    /// genuinely ambiguous corrections unmade.
    public var layoutPriority: [String] {
        didSet { write(layoutPriority, Key.layoutPriority) }
    }

    public var excludedBundleIDs: Set<String> {
        didSet { write(Array(excludedBundleIDs), Key.excludedBundleIDs) }
    }

    public var manualShortcut: Shortcut { didSet { encode(manualShortcut, Key.manualShortcut) } }
    public var revertShortcut: Shortcut { didSet { encode(revertShortcut, Key.revertShortcut) } }

    /// Off keeps the recent-corrections list in memory only, so nothing typed
    /// survives a restart.
    public var keepHistoryOnDisk: Bool { didSet { write(keepHistoryOnDisk, Key.keepHistoryOnDisk) } }

    /// Not persisted: pausing is always meant to be temporary.
    public var pausedUntil: Date?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? true
        showHUD = defaults.object(forKey: Key.showHUD) as? Bool ?? true
        interceptCommandZ = defaults.object(forKey: Key.interceptCommandZ) as? Bool ?? true
        minimumWordLength = defaults.object(forKey: Key.minimumWordLength) as? Int ?? 3
        correctsUnknownWords = defaults.object(forKey: Key.correctsUnknownWords) as? Bool ?? true
        sensitivity = defaults.string(forKey: Key.sensitivity)
            .flatMap(Sensitivity.init(rawValue:)) ?? .balanced
        usesSurroundingText = defaults.object(forKey: Key.usesSurroundingText) as? Bool ?? true
        disabledLayoutIDs = Set(defaults.stringArray(forKey: Key.disabledLayoutIDs) ?? [])
        layoutPriority = defaults.stringArray(forKey: Key.layoutPriority) ?? []
        excludedBundleIDs = Set(defaults.stringArray(forKey: Key.excludedBundleIDs) ?? [])
        keepHistoryOnDisk = defaults.object(forKey: Key.keepHistoryOnDisk) as? Bool ?? true

        manualShortcut = Self.decode(Key.manualShortcut, from: defaults) ?? .defaultManual
        revertShortcut = Self.decode(Key.revertShortcut, from: defaults) ?? .defaultRevert

        loaded = true
    }

    /// True when corrections should be happening right now.
    public var isActive: Bool {
        guard isEnabled else { return false }
        guard let pausedUntil else { return true }
        return Date() >= pausedUntil
    }

    public func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
    }

    public func resume() {
        pausedUntil = nil
    }

    public func isWatching(_ layout: KeyboardLayout) -> Bool {
        !disabledLayoutIDs.contains(layout.id)
    }

    public func setWatching(_ watching: Bool, for layout: KeyboardLayout) {
        if watching {
            disabledLayoutIDs.remove(layout.id)
        } else {
            disabledLayoutIDs.insert(layout.id)
        }
    }

    // MARK: - Order

    /// `layouts` in the user's order.
    ///
    /// A layout they have never placed — one installed since they last looked —
    /// keeps the position the system gave it, after everything they have placed.
    public func ordered(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
        guard !layoutPriority.isEmpty else { return layouts }
        return layouts
            .enumerated()
            .sorted { left, right in
                (position(of: left.element), left.offset) < (position(of: right.element), right.offset)
            }
            .map(\.element)
    }

    /// Moves one layout a single place and writes the whole order back, so the
    /// list stops depending on what the system happens to report next time.
    public func movePriority(
        of layout: KeyboardLayout,
        by offset: Int,
        within layouts: [KeyboardLayout]
    ) {
        var ids = ordered(layouts).map(\.id)
        guard
            let index = ids.firstIndex(of: layout.id),
            ids.indices.contains(index + offset)
        else { return }

        ids.swapAt(index, index + offset)
        layoutPriority = ids
    }

    private func position(of layout: KeyboardLayout) -> Int {
        layoutPriority.firstIndex(of: layout.id) ?? layoutPriority.count
    }

    // MARK: - Persistence

    private func write(_ value: Any, _ key: String) {
        guard loaded else { return }
        defaults.set(value, forKey: key)
    }

    private func encode(_ shortcut: Shortcut, _ key: String) {
        guard loaded, let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode(_ key: String, from defaults: UserDefaults) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}
