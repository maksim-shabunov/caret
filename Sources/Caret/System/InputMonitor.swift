import CaretCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Something the keyboard did that Caret cares about.
public enum InputEvent: Sendable {
    /// An ordinary key that produced text.
    case keystroke(Keystroke)
    /// The manual-conversion shortcut. Swallowed, never reaches the app.
    case manualTrigger
    /// The revert shortcut.
    case revertTrigger
    /// ⌘Z pressed while a correction was still undoable. Swallowed.
    case undoRequested
    /// Something that means the caret may have moved: a click, a modifier
    /// change, a window switch.
    case contextChanged
}

/// The watching half of Caret.
///
/// A `CGEventTap` on a thread of its own, doing as little as possible. It
/// classifies each key press and hands it to the main actor; every decision
/// about meaning happens there. The only judgements made here are the ones that
/// have to be synchronous, because the answer decides whether the key reaches
/// the app at all.
public final class InputMonitor: @unchecked Sendable {

    /// Stamped onto every event Caret posts itself, so the tap can recognise its
    /// own handiwork coming back round and let it straight through. Without
    /// this, replacing text would look like more typing and the engine would
    /// chase its own tail.
    static let syntheticMarker: Int64 = 0x4361_7265_7401

    /// What the callback needs to know, kept in a lock because it is written on
    /// the main actor and read on the tap thread.
    struct Snapshot: Sendable {
        var isActive = false
        var manualShortcut = Shortcut.defaultManual
        var revertShortcut = Shortcut.defaultRevert
        var interceptCommandZ = true
        /// True while a correction is still within its undo window.
        var undoArmed = false
        /// True when the frontmost app is on the exclusion list.
        var isExcludedApp = false
    }

    /// The tap and the thread servicing it.
    ///
    /// Guarded by `lifecycle`, because the tap thread has to reach the port — the
    /// system asks for a disabled tap to be switched back on by sending an event
    /// through it — while the main actor may be taking that same port down.
    ///
    /// An `NSLock` rather than the `OSAllocatedUnfairLock` used above it, for the
    /// dull reason that everything in here is a CoreFoundation reference and none
    /// of those are `Sendable`. They are all perfectly safe to retain and to call
    /// from any thread; the compiler simply has no way of being told so.
    private struct Machinery {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        /// Bumped every time a tap is built, so a servicing thread that has been
        /// superseded can tell that it has.
        var generation = 0
        /// True from the moment the servicing run loop starts to the moment it
        /// returns. A run loop with no valid source left returns immediately —
        /// which is exactly what happens when the system invalidates the tap
        /// underneath it — so this going false on its own is how Caret finds out.
        var isServicing = false
        /// Set while the tap is being taken down deliberately, so a thread
        /// finishing is not mistaken for a fault.
        var isStopping = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let lifecycle = NSLock()
    /// Guarded by `lifecycle`.
    private var machinery = Machinery()
    private let handler: @Sendable (InputEvent) -> Void

    private var thread: Thread?
    private let threadReady = DispatchSemaphore(value: 0)

    public init(handler: @escaping @Sendable (InputEvent) -> Void) {
        self.handler = handler
    }

    // MARK: - Configuration

    public func update(
        isActive: Bool,
        manualShortcut: Shortcut,
        revertShortcut: Shortcut,
        interceptCommandZ: Bool,
        isExcludedApp: Bool
    ) {
        state.withLock {
            $0.isActive = isActive
            $0.manualShortcut = manualShortcut
            $0.revertShortcut = revertShortcut
            $0.interceptCommandZ = interceptCommandZ
            $0.isExcludedApp = isExcludedApp
        }
    }

    public func setUndoArmed(_ armed: Bool) {
        state.withLock { $0.undoArmed = armed }
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { lifecycle.withLock { machinery.tap != nil } }

    /// Whether the tap is still there, still switched on, and still being
    /// serviced.
    ///
    /// All three can stop being true with nothing said about it. The system
    /// switches a tap off when its callback overruns, when the machine sleeps,
    /// and when Accessibility is withdrawn; it invalidates the port outright
    /// often enough that the run loop servicing it can simply run out of work and
    /// return. None of that is fatal — but an object that still exists while
    /// hearing nothing is worse than no object at all, because it reports
    /// success. So the answer has to come from asking the system, every time.
    public var isHealthy: Bool {
        let current = lifecycle.withLock { machinery }
        guard let tap = current.tap, current.isServicing else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Returns false if the tap could not be created, which in practice always
    /// means Accessibility permission has not been granted.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }

        // Modifier presses are deliberately not watched. Shift arrives before
        // every capital letter, so treating a modifier as a context change would
        // throw away every word that starts a sentence.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diagnostics.tap.error("The event tap could not be created; Accessibility permission is missing")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let generation = lifecycle.withLock { () -> Int in
            let generation = machinery.generation + 1
            machinery = Machinery(tap: tap, source: source, generation: generation)
            return generation
        }

        startThread(generation: generation)
        CGEvent.tapEnable(tap: tap, enable: true)
        // `notice` rather than `info` because info-level messages are not kept on
        // disk. This is the line that dates the tap, and it is only worth having if
        // it is still there tomorrow, when the report of going deaf arrives.
        Diagnostics.tap.notice("Event tap started")
        return true
    }

    public func stop() {
        // Cleared under the lock before anything is torn down, so a keystroke
        // arriving in the meantime finds nothing to switch back on.
        let previous = lifecycle.withLock { () -> Machinery in
            let previous = machinery
            machinery.isStopping = true
            machinery.tap = nil
            machinery.source = nil
            machinery.runLoop = nil
            return previous
        }

        guard let tap = previous.tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop = previous.runLoop { CFRunLoopStop(runLoop) }
        CFMachPortInvalidate(tap)
        thread = nil
        Diagnostics.tap.notice("Event tap stopped")
    }

    /// Takes the tap down and builds it again from nothing.
    ///
    /// The cure for every way a tap can die that cannot be cured in place. Before
    /// this existed the only cure was quitting Caret and starting it again, which
    /// is what the user had to do.
    @discardableResult
    public func restart() -> Bool {
        Diagnostics.tap.notice("Rebuilding the event tap")
        stop()
        return start()
    }

    /// The tap gets its own thread so a slow moment anywhere else in the app can
    /// never stall the keyboard. The run loop here does nothing but service the
    /// tap.
    private func startThread(generation: Int) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()

            let source = lifecycle.withLock { () -> CFRunLoopSource? in
                guard machinery.generation == generation else { return nil }
                machinery.runLoop = loop
                machinery.isServicing = true
                return machinery.source
            }
            if let source {
                CFRunLoopAddSource(loop, source, .commonModes)
            }
            threadReady.signal()
            CFRunLoopRun()

            // Two things end that call: `stop`, or the run loop running out of
            // valid sources to watch — which means the system invalidated the tap
            // underneath it. The second is the one worth knowing about, and used
            // to leave Caret deaf with every outward sign of working.
            let expected = lifecycle.withLock { () -> Bool in
                guard machinery.generation == generation else { return true }
                machinery.isServicing = false
                return machinery.isStopping
            }
            if !expected {
                Diagnostics.tap.error("The event tap stopped being serviced on its own")
            }
        }
        thread.name = "com.maksim.caret.input"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        threadReady.wait()
    }

    // MARK: - The callback

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // The system switches the tap off if it ever takes too long, and after
        // certain user input. Neither is fatal as long as it gets switched back
        // on; being silently deaf afterwards would be. Logged rather than
        // swallowed, because a tap that keeps needing this is a bug of its own.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            if let tap = lifecycle.withLock({ machinery.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
                Diagnostics.tap.error("The system switched the tap off (\(reason, privacy: .public)); switched it back on")
            } else {
                Diagnostics.tap.error("The system switched the tap off (\(reason, privacy: .public)) and there was no tap left to switch on")
            }
            return nil
        }

        // Caret's own replacement keystrokes, coming back round.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return passthrough
        }

        let snapshot = state.withLock { $0 }

        guard type == .keyDown else {
            // A click puts the caret somewhere Caret cannot account for.
            handler(.contextChanged)
            return passthrough
        }

        // Password fields. Nothing typed here is looked at, buffered, or
        // recorded — Caret simply goes blind until the field is gone.
        //
        // This is the one Carbon call made off the main thread, and the tap
        // thread is the only place in Caret that makes it.
        if IsSecureEventInputEnabled() {
            handler(.contextChanged)
            return passthrough
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modifiers = Shortcut.Modifiers(flags)

        if snapshot.isActive, !snapshot.isExcludedApp {
            if matches(snapshot.manualShortcut, keyCode: keyCode, modifiers: modifiers) {
                handler(.manualTrigger)
                return nil
            }
            if matches(snapshot.revertShortcut, keyCode: keyCode, modifiers: modifiers) {
                handler(.revertTrigger)
                return nil
            }
            // ⌘Z is only taken while a correction is still undoable, and given
            // straight back the moment the window closes. The app underneath
            // keeps its own undo stack the rest of the time.
            if snapshot.undoArmed, snapshot.interceptCommandZ,
               keyCode == 6, modifiers == [.command] {
                handler(.undoRequested)
                return nil
            }
        }

        handler(.keystroke(Keystroke(
            keyCode: keyCode,
            shift: flags.contains(.maskShift),
            capsLock: flags.contains(.maskAlphaShift),
            hasCommandChord: flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate),
            text: event.typedText,
            timestamp: Date().timeIntervalSinceReferenceDate
        )))

        return passthrough
    }

    private func matches(
        _ shortcut: Shortcut,
        keyCode: UInt16,
        modifiers: Shortcut.Modifiers
    ) -> Bool {
        shortcut.keyCode == keyCode && shortcut.modifiers == modifiers
    }
}

// MARK: - Event helpers

extension Shortcut.Modifiers {
    init(_ flags: CGEventFlags) {
        var result: Shortcut.Modifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        self = result
    }
}

extension CGEvent {
    /// The text this key press produced, as the active layout rendered it.
    var typedText: String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }

        let text = String(utf16CodeUnits: buffer, count: length)
        // Keys that are not text still report a character here: return and tab
        // give control codes, and the arrow and function keys give private-use
        // scalars. Reporting nothing for them lets the typing buffer treat them
        // as what they are — keys it does not model — rather than as letters.
        let isText = text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 32 && scalar.value != 127 && !(0xE000...0xF8FF).contains(scalar.value)
        }
        return isText ? text : ""
    }
}
