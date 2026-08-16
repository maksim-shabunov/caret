import Foundation

/// One physical key press, recorded exactly as it arrived.
///
/// The keycode is the important part: it is layout-independent, so replaying it
/// through a different keyboard layout reconstructs precisely what the user
/// *would* have typed had that layout been active. `text` is only what the key
/// actually produced under the layout that was live at the time.
public struct Keystroke: Sendable, Equatable {
    public var keyCode: UInt16
    public var shift: Bool
    public var capsLock: Bool
    /// True if command, control or option was held. Those are commands, not text.
    public var hasCommandChord: Bool
    public var text: String
    public var timestamp: TimeInterval

    public init(
        keyCode: UInt16,
        shift: Bool,
        capsLock: Bool = false,
        hasCommandChord: Bool = false,
        text: String,
        timestamp: TimeInterval
    ) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
        self.hasCommandChord = hasCommandChord
        self.text = text
        self.timestamp = timestamp
    }
}

/// A completed run of keystrokes plus the text it produced.
public struct Token: Sendable, Equatable {
    public var keystrokes: [Keystroke]
    public var text: String
    /// Characters typed after the token closed (usually the single space or
    /// punctuation mark that ended it). Needed so replacement can reach back
    /// past them to the token itself.
    public var trailing: String

    public init(keystrokes: [Keystroke], text: String, trailing: String = "") {
        self.keystrokes = keystrokes
        self.text = text
        self.trailing = trailing
    }

    public var isEmpty: Bool { text.isEmpty }
}
