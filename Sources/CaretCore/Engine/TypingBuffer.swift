import Foundation

/// Accumulates keystrokes into tokens and knows when to give up on them.
///
/// Value semantics on purpose: all the ordering and invalidation rules are
/// testable without a running event tap. The tap owns one of these behind a
/// lock and does nothing else.
public struct TypingBuffer: Sendable {

    public struct Configuration: Sendable {
        /// Hard cap on a single unbroken run of typing.
        public var maximumKeystrokes: Int = 120
        /// A pause longer than this ends the current run; the user has moved on.
        public var idleTimeout: TimeInterval = 4
        /// How many finished tokens to keep for the manual trigger.
        public var retainedTokens: Int = 3

        public init() {}
    }

    public private(set) var pending: [Keystroke] = []
    public private(set) var recentTokens: [Token] = []

    private var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Key codes that are never text

    private enum Key {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let enter: UInt16 = 76
        static let forwardDelete: UInt16 = 117

        /// Arrows, home/end, page up/down. Any of these means the caret moved
        /// somewhere Caret cannot account for.
        static let navigation: Set<UInt16> = [
            123, 124, 125, 126,           // arrows
            115, 119, 116, 121,           // home, end, page up, page down
        ]

        static let boundaries: Set<UInt16> = [returnKey, tab, space, enter]
    }

    // MARK: - Input

    /// Feeds one keystroke in. Returns a finished token when this keystroke
    /// ended one.
    ///
    /// Only whitespace closes a token. That looks conservative but is forced:
    /// `.` and `,` are Cyrillic letters on the Russian layout, and `;`, `'`,
    /// `[`, `]` are vowels on the Estonian one. Treating any of them as a word
    /// boundary would slice mistyped words in half — exactly the words Caret
    /// exists to repair.
    public mutating func append(_ keystroke: Keystroke) -> Token? {
        // A long pause means the previous run is no longer connected to this one.
        if let last = pending.last, keystroke.timestamp - last.timestamp > configuration.idleTimeout {
            invalidate()
        }

        if Key.navigation.contains(keystroke.keyCode) || keystroke.keyCode == Key.escape {
            invalidate()
            return nil
        }

        if keystroke.keyCode == Key.delete {
            if pending.isEmpty {
                // Deleting into text Caret never saw. Stop tracking.
                invalidate()
            } else {
                pending.removeLast()
            }
            return nil
        }

        if keystroke.keyCode == Key.forwardDelete {
            invalidate()
            return nil
        }

        // Modifier chords are commands, and they may well have moved the caret.
        if keystroke.hasCommandChord {
            invalidate()
            return nil
        }

        if Key.boundaries.contains(keystroke.keyCode) {
            return closeToken(trailing: keystroke.text)
        }

        // Anything that produced no text is a key Caret does not model.
        guard !keystroke.text.isEmpty else {
            invalidate()
            return nil
        }

        pending.append(keystroke)

        if pending.count > configuration.maximumKeystrokes {
            invalidate()
        }

        return nil
    }

    /// Drops everything in flight. Called on app switches, mouse clicks, focus
    /// changes and secure input.
    public mutating func invalidate() {
        pending.removeAll(keepingCapacity: true)
    }

    /// Drops in-flight *and* remembered tokens. Used when the context changes
    /// completely, so the manual trigger cannot reach into a different app's
    /// text.
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        recentTokens.removeAll(keepingCapacity: true)
    }

    // MARK: - Reading

    /// The token being typed right now, if any. This is what the manual trigger
    /// acts on when nothing is selected and no token has closed yet.
    public var currentToken: Token? {
        guard !pending.isEmpty else { return nil }
        return Token(keystrokes: pending, text: pending.map(\.text).joined())
    }

    /// The best token for the manual trigger: whatever is being typed, else the
    /// last one finished.
    public var tokenForManualTrigger: Token? {
        currentToken ?? recentTokens.last
    }

    // MARK: - Private

    private mutating func closeToken(trailing: String) -> Token? {
        defer { pending.removeAll(keepingCapacity: true) }
        guard !pending.isEmpty else { return nil }

        let token = Token(
            keystrokes: pending,
            text: pending.map(\.text).joined(),
            trailing: trailing
        )

        recentTokens.append(token)
        if recentTokens.count > configuration.retainedTokens {
            recentTokens.removeFirst(recentTokens.count - configuration.retainedTokens)
        }

        return token
    }
}
