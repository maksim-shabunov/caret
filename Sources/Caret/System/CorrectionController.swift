import AppKit
import CaretCore
import Carbon.HIToolbox
import Foundation
import Observation

/// Where everything meets: keystrokes in, corrections out.
///
/// The event tap hands raw keys to this, the engine decides, the replacer acts,
/// and history and the HUD get told. Nothing here judges language — all of that
/// lives in `CaretCore`, where it can be tested without a keyboard.
///
/// The one rule this file keeps for itself is about the caret. Caret only knows
/// where the insertion point is by remembering what it has seen since it last
/// looked; every keystroke and every click gives that up. `caretIsUndisturbed`
/// records it, and nothing that deletes text without checking is allowed to run
/// while it is false.
@MainActor
@Observable
public final class CorrectionController {

    // MARK: - Observable state

    public private(set) var layouts: [KeyboardLayout] = []
    public private(set) var activeLayout: KeyboardLayout?
    public private(set) var isMonitoring = false

    /// Set when the tap could not be created, which in practice always means
    /// Accessibility permission is missing.
    public private(set) var lastStartFailed = false

    // MARK: - Collaborators

    @ObservationIgnored public let preferences: Preferences
    @ObservationIgnored public let history: HistoryStore

    /// Called when a correction lands, for the HUD to show. A one-off event
    /// rather than state, so it is a callback and not a property.
    @ObservationIgnored public var onCorrection: ((CorrectionProposal) -> Void)?

    @ObservationIgnored private let engine: CorrectionEngine
    @ObservationIgnored private let models = LanguageModelLibrary()
    @ObservationIgnored private let recent = ContextWindow()
    @ObservationIgnored private let undo = UndoCoordinator()
    @ObservationIgnored private var monitor: InputMonitor?
    @ObservationIgnored private var buffer = TypingBuffer()
    @ObservationIgnored private var pauseTimer: Timer?
    @ObservationIgnored private var healthTimer: Timer?

    /// The frontmost app, read when it changes rather than on every keystroke.
    @ObservationIgnored private var frontmostBundleID: String?
    @ObservationIgnored private var frontmostAppName = ""

    /// True while the caret is still exactly where Caret last left it.
    @ObservationIgnored private var caretIsUndisturbed = false

    /// A manual conversion in progress. Pressing the shortcut again walks on to
    /// the next layout instead of repeating the first.
    @ObservationIgnored private var cycle: ManualCycle?

    private struct ManualCycle {
        /// What the user actually typed, which is what undo restores.
        var source: String
        /// What is on screen at the moment.
        var current: String
        var trailing: String
        var candidates: [CorrectionProposal]
        var index: Int
    }

    public init(preferences: Preferences, history: HistoryStore) {
        self.preferences = preferences
        self.history = history
        engine = CorrectionEngine(
            lexicon: SystemSpellLexicon(),
            models: models,
            minimumLength: preferences.minimumWordLength,
            correctsUnknownWords: preferences.correctsUnknownWords,
            usesContext: preferences.usesSurroundingText,
            sensitivity: preferences.sensitivity,
            layoutPriority: preferences.layoutPriority
        )

        refreshLayouts()
        refreshFrontmostApp()
        observeSystemChanges()

        undo.onArmedChange = { [weak self] armed in
            self?.monitor?.setUndoArmed(armed)
        }
    }

    /// Trains the character models in the background, for whichever languages the
    /// installed layouts actually use.
    ///
    /// A few hundred milliseconds of arithmetic, which is far too long to spend
    /// on the main thread and far too long to spend at all if nobody has a
    /// Russian keyboard installed. Until it finishes the models are simply
    /// absent, and Caret behaves exactly as it did before they existed — the
    /// dictionary rules do not wait for anything.
    private func warmModels() {
        let languages = Set(layouts.map(\.primaryLanguage)).sorted()
        Task { [models] in
            await models.warm(languages: languages)
        }
    }

    // MARK: - Lifecycle

    /// Starts watching. Returns false if the tap could not be created.
    @discardableResult
    public func start() -> Bool {
        // A monitor that exists is not the same as a monitor that works: the
        // system can switch its tap off or invalidate it outright, and what is
        // left reports success while hearing nothing. Asking used to be
        // impossible, so this returned early and the only cure was a relaunch.
        if let monitor {
            if monitor.isHealthy { return true }
            Diagnostics.tap.error("Found a dead input tap while starting; rebuilding it")
            monitor.stop()
            self.monitor = nil
        }

        let monitor = InputMonitor { [weak self] event in
            // The tap thread must never wait on anything, so events are handed
            // over and the callback returns immediately. `DispatchQueue.main`
            // rather than a `Task`, because keystrokes have to arrive in the
            // order they were typed and only a serial queue promises that.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.receive(event)
                }
            }
        }
        self.monitor = monitor

        guard monitor.start() else {
            self.monitor = nil
            lastStartFailed = true
            isMonitoring = false
            return false
        }

        lastStartFailed = false
        isMonitoring = true
        preferencesChanged()
        startHealthChecks()
        return true
    }

    public func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        monitor?.stop()
        monitor = nil
        isMonitoring = false
        forgetContext()
    }

    // MARK: - Staying alive

    /// How often to check that Caret can still hear anything. Two cheap reads,
    /// and the difference between a five-second gap and an app that has to be
    /// quit and started again.
    private static let healthInterval: TimeInterval = 5

    /// Checks the two things that can stop working with nothing said about it,
    /// and puts them back.
    ///
    /// The event tap is the first. The system switches taps off — a callback that
    /// overran, a machine that slept, a screen that locked, a permission
    /// withdrawn — and sometimes invalidates them outright, and none of it is
    /// announced. What was left behind still looked like a working monitor, so
    /// Caret went on believing it was watching while hearing nothing, and only
    /// quitting it helped.
    ///
    /// The active keyboard layout is the second. Reading it can fail, and until
    /// it succeeds the engine has nothing to compare a word against, so every
    /// keystroke is dropped. That read is normally only retried when the user
    /// switches layout, which is no use to someone who has not touched it.
    public func verifyHealth() {
        if let monitor, !monitor.isHealthy {
            Diagnostics.tap.error("The input tap has stopped working; rebuilding it")
            if monitor.restart() {
                syncMonitor()
                isMonitoring = true
                lastStartFailed = false
            } else {
                self.monitor = nil
                isMonitoring = false
                lastStartFailed = true
                Diagnostics.tap.error("The input tap could not be rebuilt")
            }
        }

        // Only what is actually missing is re-read: building a layout's key map
        // is a few hundred calls into Carbon, and this runs on a timer.
        if layouts.isEmpty {
            layouts = KeyboardLayoutReader.enabledLayouts()
        }
        if activeLayout == nil {
            activeLayout = KeyboardLayoutReader.currentLayout()
            if activeLayout != nil {
                Diagnostics.layouts.notice("The active keyboard layout could be read again")
            }
        }
    }

    private func startHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(
            withTimeInterval: Self.healthInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.verifyHealth()
            }
        }
    }

    /// Applies the current preferences to everything the controller owns.
    /// Called by the UI whenever a setting changes.
    public func preferencesChanged() {
        engine.minimumLength = preferences.minimumWordLength
        engine.correctsUnknownWords = preferences.correctsUnknownWords
        engine.sensitivity = preferences.sensitivity
        engine.usesContext = preferences.usesSurroundingText
        engine.layoutPriority = preferences.layoutPriority
        // Switching it off drops what was already held, rather than leaving it
        // sitting in memory until the app is quit.
        if !preferences.usesSurroundingText { recent.clear() }
        history.setPersists(preferences.keepHistoryOnDisk)
        syncMonitor()
        schedulePauseExpiry()
    }

    private func syncMonitor() {
        monitor?.update(
            isActive: preferences.isActive,
            manualShortcut: preferences.manualShortcut,
            revertShortcut: preferences.revertShortcut,
            interceptCommandZ: preferences.interceptCommandZ,
            isExcludedApp: isFrontmostAppExcluded
        )
    }

    /// A pause ends by the clock, with nothing to announce it. Without this the
    /// tap would keep the stale answer and Caret would stay quiet for good.
    private func schedulePauseExpiry() {
        pauseTimer?.invalidate()
        pauseTimer = nil

        guard let until = preferences.pausedUntil else { return }
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else { return }

        pauseTimer = Timer.scheduledTimer(withTimeInterval: remaining + 0.1, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.preferences.resume()
                self.syncMonitor()
            }
        }
    }

    // MARK: - Layouts

    /// Re-reads the installed layouts and the one in use.
    ///
    /// An empty answer is treated as a failed read rather than as an answer. A
    /// machine always has at least one keyboard layout, so nothing is the system
    /// declining to say — and writing that down would leave the engine with
    /// nowhere to convert to and no way of noticing, until Caret was restarted.
    public func refreshLayouts() {
        let installed = KeyboardLayoutReader.enabledLayouts()
        if installed.isEmpty {
            Diagnostics.layouts.error("The system reported no keyboard layouts; keeping the ones already known")
        } else {
            layouts = installed
        }

        let current = KeyboardLayoutReader.currentLayout()
        if current == nil, activeLayout != nil {
            // Caret genuinely cannot judge anything now — but `verifyHealth` will
            // keep asking, so this is a pause rather than the end.
            Diagnostics.layouts.error("The active keyboard layout could not be read; standing down until it can")
        }
        activeLayout = current

        // A layout the user just installed may bring a language with it.
        warmModels()
    }

    /// The layouts the engine may convert *to*, in the order the user prefers
    /// them. The order is what settles a correction two layouts could both claim.
    private var watchedLayouts: [KeyboardLayout] {
        preferences.ordered(layouts.filter(preferences.isWatching))
    }

    // MARK: - Context

    private func observeSystemChanges() {
        let distributed = DistributedNotificationCenter.default()
        let layoutNotifications: [String] = [
            kTISNotifySelectedKeyboardInputSourceChanged as String,
            kTISNotifyEnabledKeyboardInputSourcesChanged as String,
        ]
        for name in layoutNotifications {
            distributed.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshLayouts()
                    // Switching layout part-way through a word means the keys on
                    // record and the live layout no longer agree.
                    //
                    // The window of recent text needs no telling: it is handed
                    // the layout along with the text, and drops what it holds the
                    // moment the two stop matching.
                    self.buffer.invalidate()
                }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshFrontmostApp()
                // Different app, different text. Forget all of it, so nothing
                // can reach back into the app the user just left.
                self.forgetContext()
                self.syncMonitor()
                // Free, and the moment it matters most: someone who has just
                // switched app is about to type.
                self.verifyHealth()
            }
        }

        // Sleeping, locking the screen and switching user are the moments the
        // system is most likely to have taken the tap away, and all three are
        // followed by the user coming back and typing straight away — so they are
        // checked at once rather than waited for.
        let resumed: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in resumed {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.verifyHealth()
                }
            }
        }
    }

    private func refreshFrontmostApp() {
        let app = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = app?.bundleIdentifier
        frontmostAppName = app?.localizedName ?? ""
    }

    private var isFrontmostAppExcluded: Bool {
        guard let frontmostBundleID else { return false }
        return preferences.excludedBundleIDs.contains(frontmostBundleID)
    }

    /// Drops everything Caret was holding about the text on screen.
    private func forgetContext() {
        buffer.reset()
        recent.clear()
        undo.clear()
        cycle = nil
        caretIsUndisturbed = false
    }

    // MARK: - Events

    private func receive(_ event: InputEvent) {
        switch event {
        case .contextChanged:
            // A click, or a secure field taking over. The caret is somewhere
            // Caret cannot account for, so everything that assumes it knows
            // where it is has to go. The last correction is deliberately kept:
            // "undo at any time" means the shortcut still works a click later,
            // and the search-and-verify path can do that safely. Only ⌘Z is
            // given up, because the user now means it for wherever they clicked.
            //
            // The window of recent text goes too. Whatever is before the caret
            // now, Caret did not see it — and in a secure field this is the only
            // thing standing between a password and being kept in memory.
            buffer.reset()
            recent.clear()
            cycle = nil
            caretIsUndisturbed = false
            undo.relinquishCommandZ()
        case .keystroke(let keystroke):
            handle(keystroke)
        case .manualTrigger:
            convertManually()
        case .revertTrigger, .undoRequested:
            revert()
        }
    }

    private func handle(_ keystroke: Keystroke) {
        // Anything typed moves the insertion point past what Caret last saw.
        caretIsUndisturbed = false
        cycle = nil

        guard preferences.isActive, !isFrontmostAppExcluded else {
            buffer.reset()
            return
        }

        guard let token = buffer.append(keystroke), let activeLayout else { return }

        let proposal = engine.evaluate(
            token: token,
            activeLayout: activeLayout,
            candidateLayouts: watchedLayouts,
            context: recent.context(
                app: frontmostBundleID,
                layout: activeLayout.id,
                at: keystroke.timestamp
            )
        )

        var landed = token.text
        if let proposal, apply(proposal, trailing: token.trailing) {
            landed = proposal.corrected
        }

        // What goes into the window is what is on screen, not what was typed. A
        // word Caret just fixed has to speak for the language it was fixed into;
        // otherwise the first correction in a sentence would leave the window
        // insisting the user writes Latin, and the next word would suffer for it.
        if preferences.usesSurroundingText {
            recent.note(
                landed + token.trailing,
                app: frontmostBundleID,
                layout: activeLayout.id,
                at: keystroke.timestamp
            )
        }
    }

    /// Performs a correction and records it. Returns whether it reached the
    /// screen; a refusal from the replacer leaves the typed text standing.
    ///
    /// Blind typing is allowed here because this runs on the keystroke that
    /// closed the token: the caret is, by construction, immediately after the
    /// text being replaced.
    @discardableResult
    private func apply(_ proposal: CorrectionProposal, trailing: String) -> Bool {
        guard TextReplacer.replace(
            original: proposal.original,
            with: proposal.corrected,
            trailing: trailing
        ) != nil else { return false }

        caretIsUndisturbed = true

        let record = CorrectionRecord(
            original: proposal.original,
            corrected: proposal.corrected,
            layoutName: proposal.targetLayoutName,
            applicationName: frontmostAppName
        )
        history.add(record)

        undo.arm(
            recordID: record.id,
            original: proposal.original,
            corrected: proposal.corrected,
            trailing: trailing
        )

        onCorrection?(proposal)

        // The replacement is on screen now, but the buffer still holds the keys
        // that produced the original. Start fresh.
        buffer.invalidate()
        return true
    }

    // MARK: - Undo

    /// Puts back exactly what the user typed, and makes sure it stays put.
    public func revert() {
        guard let reverted = undo.revert(caretIsUndisturbed: caretIsUndisturbed) else { return }

        history.markReverted(id: reverted.recordID)
        // Never offer this word again this session. Without it the next
        // keystroke would helpfully re-apply the very correction just rejected.
        engine.suppress(reverted.original)

        buffer.invalidate()
        cycle = nil
        caretIsUndisturbed = false
    }

    // MARK: - Manual conversion

    /// Converts the selection if there is one, otherwise the word just typed.
    ///
    /// Pressing again walks on to the next layout, which is how the user picks
    /// when more than one conversion is plausible.
    public func convertManually() {
        guard let activeLayout else { return }

        if let selection = TextReplacer.selectedText() {
            convert(text: selection, trailing: "", from: activeLayout) { replacement in
                TextReplacer.replaceSelection(with: replacement) != nil
            }
            return
        }

        // Continuing a cycle: what is on screen is Caret's own last replacement,
        // still sitting under the caret.
        if caretIsUndisturbed, let cycle {
            convert(text: cycle.current, trailing: cycle.trailing, from: activeLayout) { replacement in
                TextReplacer.replace(
                    original: cycle.current,
                    with: replacement,
                    trailing: cycle.trailing
                ) != nil
            }
            return
        }

        guard let token = buffer.tokenForManualTrigger, !token.isEmpty else { return }
        convert(text: token.text, trailing: token.trailing, from: activeLayout) { replacement in
            TextReplacer.replace(
                original: token.text,
                with: replacement,
                trailing: token.trailing
            ) != nil
        }
    }

    private func convert(
        text: String,
        trailing: String,
        from source: KeyboardLayout,
        replace: (String) -> Bool
    ) {
        // A cycle already under way on this exact text moves on; anything else
        // starts a new one.
        let continuing = cycle?.current == text ? cycle : nil
        // Unwatched layouts included on purpose: the user asked by hand, so every
        // reading is on the table. The order is theirs, so the first press offers
        // the language they said they mostly write.
        let candidates = continuing?.candidates
            ?? engine.manualCandidates(
                for: text,
                from: source,
                layouts: preferences.ordered(layouts)
            )
        guard !candidates.isEmpty else { return }

        let index = continuing.map { ($0.index + 1) % candidates.count } ?? 0
        let next = candidates[index]
        guard replace(next.corrected) else { return }

        caretIsUndisturbed = true

        // Undo restores what the user typed, not the previous step of the cycle.
        let original = continuing?.source ?? text
        cycle = ManualCycle(
            source: original,
            current: next.corrected,
            trailing: trailing,
            candidates: candidates,
            index: index
        )

        let record = CorrectionRecord(
            original: original,
            corrected: next.corrected,
            layoutName: next.targetLayoutName,
            applicationName: frontmostAppName
        )
        history.add(record)

        undo.arm(
            recordID: record.id,
            original: original,
            corrected: next.corrected,
            trailing: trailing
        )

        onCorrection?(next)
        buffer.invalidate()

        // A hand-made conversion is still text arriving on screen, so the window
        // hears about it. If the word had already closed and gone in unconverted
        // the window now holds both readings, which reads as a sentence with no
        // clear language — and no language means no context, which is the safe
        // answer rather than a wrong one.
        if preferences.usesSurroundingText {
            recent.note(
                next.corrected + trailing,
                app: frontmostBundleID,
                layout: source.id,
                at: Date().timeIntervalSinceReferenceDate
            )
        }
    }
}
