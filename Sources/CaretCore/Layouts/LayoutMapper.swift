import Foundation

/// Converts text between keyboard layouts.
///
/// Two routes exist, and the difference matters:
///
/// * **Keycode route** — used for automatic corrections, where Caret watched the
///   keys go by. Exact: it replays the physical keys through another layout, so
///   case, shift state and punctuation all survive.
/// * **Character route** — used for the manual trigger on a selection, where no
///   keystrokes were observed and all Caret has is the text. It infers which key
///   would have produced each character, then replays that. Slightly lossier:
///   characters the source layout cannot produce pass through untouched.
public enum LayoutMapper {

    // MARK: - Keycode route

    /// Replays recorded keystrokes through `target`.
    ///
    /// Returns `nil` if any keystroke has no equivalent on the target layout,
    /// because a partial conversion would be worse than none.
    public static func translate(
        keystrokes: [Keystroke],
        to target: KeyboardLayout
    ) -> String? {
        guard !keystrokes.isEmpty else { return nil }

        var result = ""
        for keystroke in keystrokes {
            guard
                let text = target.character(
                    for: keystroke.keyCode,
                    shift: keystroke.shift,
                    capsLock: keystroke.capsLock
                )
            else { return nil }
            result += text
        }
        return result
    }

    // MARK: - Character route

    /// Re-types `text` as though `target` had been active instead of `source`.
    ///
    /// Characters that `source` cannot produce (emoji, characters from a third
    /// script, anything pasted) are passed through unchanged. Returns `nil` if
    /// nothing at all could be mapped — that means the text has no relationship
    /// to the source layout and converting it is meaningless.
    public static func translate(
        text: String,
        from source: KeyboardLayout,
        to target: KeyboardLayout
    ) -> String? {
        guard !text.isEmpty else { return nil }

        var result = ""
        var mappedCount = 0

        for character in text {
            // Whitespace is identical on every layout; don't count it as signal.
            if character.isWhitespace {
                result.append(character)
                continue
            }
            guard
                let key = source.reverse[character],
                let replacement = target.character(for: key.keyCode, shift: key.shift)
            else {
                result.append(character)
                continue
            }
            result += replacement
            mappedCount += 1
        }

        guard mappedCount > 0 else { return nil }
        return result
    }
}
