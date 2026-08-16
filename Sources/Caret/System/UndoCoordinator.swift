import CaretCore
import Foundation

/// Makes undoing a correction trivial and obvious.
///
/// Two ways back, because the whole feature rests on this being effortless:
///
/// * **⌘Z**, for a few seconds after a correction — the reflex everyone already
///   has. Outside that window ⌘Z belongs to the app, untouched.
/// * **The revert shortcut**, for as long as the user stays in the app they
///   were typing in — long after the ⌘Z window closed, and after clicking
///   somewhere else. Switching apps is where a correction is finally let go,
///   because reaching back into a document the user has left is not something
///   Caret should be able to do.
///
/// Reverting also tells the engine never to offer that word again this session.
/// Otherwise the next keystroke would helpfully re-apply the very correction the
/// user just rejected.
@MainActor
public final class UndoCoordinator {

    /// Long enough to notice and react, short enough that ⌘Z is back in the
    /// app's hands before it is wanted for anything else.
    public static let window: TimeInterval = 5

    public struct Pending: Sendable {
        public var recordID: UUID
        public var original: String
        public var corrected: String
        public var trailing: String
        public var appliedAt: Date
    }

    public private(set) var pending: Pending?

    /// Called whenever the undo window opens or closes, so the event tap knows
    /// whether it should be taking ⌘Z.
    public var onArmedChange: (@MainActor (Bool) -> Void)?

    private var expiry: Timer?

    public init() {}

    public var isArmed: Bool {
        guard let pending else { return false }
        return Date().timeIntervalSince(pending.appliedAt) < Self.window
    }

    public func arm(
        recordID: UUID,
        original: String,
        corrected: String,
        trailing: String
    ) {
        pending = Pending(
            recordID: recordID,
            original: original,
            corrected: corrected,
            trailing: trailing,
            appliedAt: Date()
        )
        onArmedChange?(true)

        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.window, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // The correction stays revertable by shortcut; only ⌘Z is given
                // back to the app.
                self?.onArmedChange?(false)
            }
        }
    }

    /// Puts the original text back. Returns what was reverted, so the caller can
    /// update history and suppress the word.
    ///
    /// `caretIsUndisturbed` says whether the caret is still sitting where Caret
    /// left it. When it is, the correction can simply be typed over. When it is
    /// not — the user carried on and noticed a sentence later — the word has to
    /// be found and verified first, because backspacing from wherever the caret
    /// now is would destroy live text. Not every app can be searched that way,
    /// so a late revert is allowed to fail; silence is the right failure.
    public func revert(caretIsUndisturbed: Bool) -> Pending? {
        guard let pending else { return nil }

        // The trailing space was typed after the correction, so it is still
        // there and must be stepped over to reach the word.
        let route = TextReplacer.replace(
            original: pending.corrected,
            with: pending.original,
            trailing: pending.trailing,
            allowBlindTyping: caretIsUndisturbed
        ) ?? TextReplacer.replaceMostRecent(pending.corrected, with: pending.original)

        guard route != nil else { return nil }

        clear()
        return pending
    }

    /// Hands ⌘Z back to the app while keeping the correction revertable.
    ///
    /// Used when the caret moves — a click, a secure field. Caret can no longer
    /// claim ⌘Z, because the user almost certainly means it for whatever they
    /// have just clicked into. The revert shortcut still works, and still finds
    /// the word by searching for it rather than by counting backspaces.
    public func relinquishCommandZ() {
        guard pending != nil else { return }
        expiry?.invalidate()
        expiry = nil
        onArmedChange?(false)
    }

    public func clear() {
        pending = nil
        expiry?.invalidate()
        expiry = nil
        onArmedChange?(false)
    }
}
