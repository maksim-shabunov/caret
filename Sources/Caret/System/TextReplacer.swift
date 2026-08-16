import AppKit
import ApplicationServices
import CaretCore
import CoreGraphics
import Foundation

/// Puts corrected text where the wrong text was.
///
/// There is no single way to do this that works everywhere, so there are two,
/// tried in order:
///
/// 1. **Accessibility.** Reads the text around the caret, checks it really is
///    what Caret expects, and swaps it in one move. Native apps handle this
///    perfectly and the app's own undo stack stays intact.
/// 2. **Synthetic keystrokes.** Backspace over the word and type the new one.
///    Works literally everywhere, including terminals and remote desktops.
///
/// The Accessibility route is always attempted first *and verified first* — it
/// only proceeds once the text it is about to replace has been read back and
/// matches. Replacing the wrong range would be far worse than not correcting.
@MainActor
public enum TextReplacer {

    public enum Route: Sendable, Equatable {
        case accessibility
        case keystrokes
    }

    /// How far back a search for already-typed text will look. Far enough to
    /// find a word a sentence or two ago, not far enough to reach into text the
    /// user has long since moved past.
    private static let lookBehind = 400

    /// Replaces `original` with `replacement` immediately before the caret.
    ///
    /// `trailing` is whatever was typed after the word — usually the space that
    /// ended it — which has to be stepped over and then put back.
    ///
    /// `allowBlindTyping` governs the fallback. Backspacing cannot check what it
    /// is deleting, so it is only safe when the caret is known to be exactly
    /// where Caret left it. Pass `false` for anything that might be happening
    /// seconds later, and accept that apps without Accessibility support will
    /// then decline the edit rather than risk eating live text.
    @discardableResult
    public static func replace(
        original: String,
        with replacement: String,
        trailing: String = "",
        allowBlindTyping: Bool = true
    ) -> Route? {
        if replaceViaAccessibility(original: original, with: replacement, trailing: trailing) {
            return .accessibility
        }
        guard allowBlindTyping else { return nil }
        if replaceViaKeystrokes(original: original, with: replacement, trailing: trailing) {
            return .keystrokes
        }
        return nil
    }

    /// Replaces the most recent occurrence of `text` in the run-up to the caret.
    ///
    /// This is how a correction stays revertable after the user has carried on
    /// typing. It only ever touches a range whose exact contents have been read
    /// back first, and it looks back a bounded distance, so the worst case is
    /// that it finds nothing and does nothing.
    @discardableResult
    public static func replaceMostRecent(_ text: String, with replacement: String) -> Route? {
        guard !text.isEmpty, let element = focusedElement() else { return nil }
        guard let caret = caretLocation(in: element), caret > 0 else { return nil }

        let window = min(caret, lookBehind)
        var probe = CFRange(location: caret - window, length: window)
        guard
            let probeValue = AXValueCreate(.cfRange, &probe),
            let recent = parameterisedValue(
                of: element,
                kAXStringForRangeParameterizedAttribute,
                parameter: probeValue
            ) as? String
        else { return nil }

        let found = (recent as NSString).range(of: text, options: .backwards)
        guard found.location != NSNotFound else { return nil }

        var target = CFRange(location: caret - window + found.location, length: found.length)
        guard
            let targetValue = AXValueCreate(.cfRange, &target),
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, targetValue
            ) == .success,
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, replacement as CFString
            ) == .success
        else { return nil }

        return .accessibility
    }

    // MARK: - Accessibility

    private static func replaceViaAccessibility(
        original: String,
        with replacement: String,
        trailing: String
    ) -> Bool {
        guard let element = focusedElement() else { return false }

        // Where the caret is. A selection rather than an insertion point means
        // the user is doing something else; leave it alone.
        guard let range = selectedRange(in: element), range.length == 0 else { return false }

        let span = (original as NSString).length + (trailing as NSString).length
        let start = range.location - span
        guard start >= 0 else { return false }

        // Read back what is actually there before touching it. If it is not
        // exactly what Caret thinks it typed — because an autocorrect fired, or
        // the app rewrote the line — this is not our text to replace.
        var target = CFRange(location: start, length: span)
        guard
            let targetValue = AXValueCreate(.cfRange, &target),
            let existing = parameterisedValue(
                of: element,
                kAXStringForRangeParameterizedAttribute,
                parameter: targetValue
            ) as? String,
            existing == original + trailing
        else { return false }

        // Select exactly that span, then substitute. One edit, so the app's own
        // undo sees a single change.
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, targetValue
        ) == .success else { return false }

        let outcome = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            (replacement + trailing) as CFString
        )
        return outcome == .success
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// The current selection, in UTF-16 units. A zero length means the caret is
    /// an insertion point.
    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        guard
            let selection = value(of: element, kAXSelectedTextRangeAttribute),
            CFGetTypeID(selection) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Where text would be inserted right now.
    private static func caretLocation(in element: AXUIElement) -> Int? {
        selectedRange(in: element).map { $0.location + $0.length }
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &result
        ) == .success else { return nil }
        return result
    }

    private static func parameterisedValue(
        of element: AXUIElement,
        _ attribute: String,
        parameter: CFTypeRef
    ) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &result
        ) == .success else { return nil }
        return result
    }

    // MARK: - Synthetic keystrokes

    /// Deletes back over the word and types the replacement.
    ///
    /// Every event is stamped so the tap recognises it as Caret's own and lets
    /// it through untouched.
    private static func replaceViaKeystrokes(
        original: String,
        with replacement: String,
        trailing: String
    ) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.userData = InputMonitor.syntheticMarker

        let deletions = original.count + trailing.count
        guard deletions > 0 else { return false }

        for _ in 0..<deletions {
            post(keyCode: 51, source: source)
        }
        type(replacement + trailing, source: source)
        return true
    }

    private static func post(keyCode: CGKeyCode, source: CGEventSource) {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Types text by attaching it to a key event rather than by finding keys
    /// that produce it — so it is independent of whichever layout is active,
    /// which is rather the point.
    private static func type(_ text: String, source: CGEventSource) {
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
            up.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticMarker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Selection, for the manual trigger

    /// The text the user has selected in the frontmost app, if any.
    public static func selectedText() -> String? {
        guard
            let element = focusedElement(),
            let selected = value(of: element, kAXSelectedTextAttribute) as? String,
            !selected.isEmpty
        else { return nil }
        return selected
    }

    /// Replaces the current selection outright, leaving the new text selected.
    ///
    /// Keeping the selection matters: it is what lets the manual trigger be
    /// pressed again to cycle to the next layout, and it shows the user exactly
    /// what changed. Typing over the result behaves as it would have anyway,
    /// since the text was selected before the shortcut too.
    @discardableResult
    public static func replaceSelection(with replacement: String) -> Route? {
        if let element = focusedElement(),
           let range = selectedRange(in: element),
           AXUIElementSetAttributeValue(
               element, kAXSelectedTextAttribute as CFString, replacement as CFString
           ) == .success {
            var replaced = CFRange(
                location: range.location,
                length: (replacement as NSString).length
            )
            if let value = AXValueCreate(.cfRange, &replaced) {
                AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, value
                )
            }
            return .accessibility
        }

        // Typing replaces a selection in every text control worth the name, so
        // there is nothing to delete first.
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = InputMonitor.syntheticMarker
        type(replacement, source: source)
        return .keystrokes
    }
}
