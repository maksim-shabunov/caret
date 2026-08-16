import Foundation

/// What Caret knows about the text around the word it is judging.
///
/// One word on its own is often not enough to decide anything. A lone `z` could
/// be an initial, a variable, or the letter someone meant to type as `я` — and
/// nothing about the `z` itself will ever say which. What settles it is the
/// sentence it landed in.
public struct TypingContext: Sendable, Equatable {
    /// The script the surrounding text is written in, where there was enough of
    /// it to be sure.
    public let script: Script?

    /// Nothing known. Every decision falls back to judging the word alone, which
    /// is what Caret did before it kept any context at all.
    public static let none = TypingContext(script: nil)

    public init(script: Script?) {
        self.script = script
    }
}

/// The last stretch of text the user typed, and nothing more.
///
/// Thirty characters, in one app, on one keyboard layout, within the last
/// minute. All four limits exist because context is only meaningful while
/// someone is in the middle of writing something:
///
///   - **Length.** Enough to tell which language a sentence is in, and little
///     enough that it follows the user from thought to thought rather than
///     anchoring them to one from ten minutes ago.
///   - **App.** Text in another window is somebody else's sentence. Switching
///     away drops it, and switching back does not bring it back — by the time
///     the user has been elsewhere, whatever they were writing has gone from
///     their head too.
///   - **Layout.** Someone who has just reached for the layout key has said, as
///     plainly as anyone can say it, which language they are about to write in.
///     What they wrote before saying it cannot speak for what comes after.
///     Without this the window went on reading Russian while the user typed
///     English, and every short English word they began with was in reach of the
///     rescue that only a Russian sentence is supposed to authorise.
///   - **Time.** A minute's silence ends a train of thought.
///
/// The layout limit is the only one that ever costs a correction, and what it
/// costs is one word: after a switch nobody chose, the ordinary rules still fix
/// whole words, and the window refills with the correction rather than the typo.
///
/// Nothing is kept beyond those thirty characters and nothing is written to disk.
/// It is a sliding window over the present moment, not a record of anything.
@MainActor
public final class ContextWindow {

    private let capacity: Int
    private let idleTimeout: TimeInterval

    private var characters: [Character] = []
    private var app: String?
    private var layout: String?
    private var lastTypedAt: TimeInterval?

    public init(capacity: Int = 30, idleTimeout: TimeInterval = 60) {
        self.capacity = capacity
        self.idleTimeout = idleTimeout
    }

    /// The text currently in the window, oldest first.
    public var text: String { String(characters) }

    /// Records text that has landed on screen.
    ///
    /// Given what is actually there rather than what was typed, so a corrected
    /// word contributes the correction. Otherwise fixing `ghbdtn` to `привет`
    /// would leave the window arguing that the user writes English.
    public func note(
        _ addition: String,
        app: String?,
        layout: String? = nil,
        at timestamp: TimeInterval
    ) {
        if app != self.app || layout != self.layout {
            characters.removeAll(keepingCapacity: true)
            self.app = app
            self.layout = layout
        } else if let lastTypedAt, timestamp - lastTypedAt > idleTimeout {
            characters.removeAll(keepingCapacity: true)
        }

        characters.append(contentsOf: addition)
        if characters.count > capacity {
            characters.removeFirst(characters.count - capacity)
        }
        lastTypedAt = timestamp
    }

    /// What the window can say about a word being typed now, in `app` on
    /// `layout`.
    ///
    /// Answers `.none` unless the text on record was typed in the same app, on
    /// the same layout, and recently enough to still be the same sentence.
    public func context(
        app: String?,
        layout: String? = nil,
        at timestamp: TimeInterval
    ) -> TypingContext {
        guard app == self.app, layout == self.layout, let lastTypedAt else { return .none }
        guard timestamp - lastTypedAt <= idleTimeout else { return .none }
        return TypingContext(script: Script.dominant(in: characters))
    }

    public func clear() {
        characters.removeAll(keepingCapacity: true)
        app = nil
        layout = nil
        lastTypedAt = nil
    }
}
