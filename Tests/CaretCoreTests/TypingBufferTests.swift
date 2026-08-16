import Foundation
import Testing
@testable import CaretCore

@Suite("Typing buffer")
struct TypingBufferTests {

    enum Key {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
        static let leftArrow: UInt16 = 123
        static let period: UInt16 = 47
        static let comma: UInt16 = 43
        static let semicolon: UInt16 = 41
    }

    /// Types text one letter at a time. Keycodes are arbitrary but distinct;
    /// the buffer never interprets them beyond the handful it treats specially.
    static func type(
        _ text: String,
        into buffer: inout TypingBuffer,
        from start: TimeInterval = 0
    ) -> [Token] {
        var tokens: [Token] = []
        for (index, character) in text.enumerated() {
            let stroke = Keystroke(
                keyCode: UInt16(60 + index % 20),
                shift: character.isUppercase,
                text: String(character),
                timestamp: start + Double(index) * 0.05
            )
            if let token = buffer.append(stroke) { tokens.append(token) }
        }
        return tokens
    }

    static func special(_ keyCode: UInt16, _ text: String = "", at time: TimeInterval = 1) -> Keystroke {
        Keystroke(keyCode: keyCode, shift: false, text: text, timestamp: time)
    }

    // MARK: - Boundaries

    @Test("A space closes the word")
    func spaceClosesToken() {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        let token = buffer.append(Self.special(Key.space, " "))
        #expect(token?.text == "hello")
        #expect(token?.trailing == " ")
        #expect(buffer.pending.isEmpty)
    }

    @Test("Return and tab close it too", arguments: [Key.returnKey, Key.tab])
    func whitespaceClosesToken(_ keyCode: UInt16) {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        #expect(buffer.append(Self.special(keyCode, "\n"))?.text == "hello")
    }

    /// The rule that makes the whole thing work. A full stop is the Cyrillic
    /// `ю`, and a semicolon is the Estonian `ö` — treating either as a word
    /// boundary would cut mistyped words in half.
    @Test("Punctuation does not close the word")
    func punctuationDoesNotCloseToken() {
        for (keyCode, text) in [(Key.period, "."), (Key.comma, ","), (Key.semicolon, ";")] {
            var buffer = TypingBuffer()
            _ = Self.type("k", into: &buffer)
            #expect(buffer.append(Self.special(keyCode, text)) == nil)
            _ = Self.type("k", into: &buffer, from: 0.5)
            #expect(buffer.currentToken?.text == "k\(text)k")
        }
    }

    @Test("A space with nothing pending produces nothing")
    func emptyTokenIsNotEmitted() {
        var buffer = TypingBuffer()
        #expect(buffer.append(Self.special(Key.space, " ")) == nil)
    }

    @Test("Consecutive words come out separately")
    func multipleTokens() {
        var buffer = TypingBuffer()
        var tokens = Self.type("one", into: &buffer)
        tokens += [buffer.append(Self.special(Key.space, " ", at: 0.2))].compactMap { $0 }
        tokens += Self.type("two", into: &buffer, from: 0.25)
        tokens += [buffer.append(Self.special(Key.space, " ", at: 0.5))].compactMap { $0 }
        #expect(tokens.map(\.text) == ["one", "two"])
    }

    // MARK: - Invalidation

    @Test("Backspace takes back the last keystroke")
    func deleteRemovesLastKeystroke() {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        #expect(buffer.append(Self.special(Key.delete)) == nil)
        #expect(buffer.currentToken?.text == "hell")
    }

    @Test("Backspacing past the start means Caret is blind to what came before")
    func deleteOnEmptyInvalidates() {
        var buffer = TypingBuffer()
        _ = Self.type("hi", into: &buffer)
        for _ in 0..<3 { _ = buffer.append(Self.special(Key.delete)) }

        // That last delete ate text Caret never saw, so it stops tracking.
        #expect(buffer.pending.isEmpty)
        #expect(buffer.currentToken == nil)

        _ = Self.type("x", into: &buffer, from: 0.4)
        #expect(buffer.currentToken?.text == "x")
    }

    @Test("Anything that moves the caret abandons the word", arguments: [
        Key.leftArrow, Key.escape, Key.forwardDelete, 124, 125, 126, 115, 116, 119, 121,
    ])
    func caretMovementInvalidates(_ keyCode: UInt16) {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        #expect(buffer.append(Self.special(keyCode)) == nil)
        #expect(buffer.pending.isEmpty)
    }

    @Test("A modifier chord abandons the word")
    func commandChordInvalidates() {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        var chord = Self.special(70, "a")
        chord.hasCommandChord = true
        #expect(buffer.append(chord) == nil)
        #expect(buffer.pending.isEmpty)
    }

    @Test("A key that produces no text is a key Caret does not model")
    func nonTextKeyInvalidates() {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        #expect(buffer.append(Self.special(63)) == nil)
        #expect(buffer.pending.isEmpty)
    }

    @Test("A long pause ends the run")
    func idleTimeoutInvalidates() {
        var buffer = TypingBuffer()
        _ = Self.type("hello", into: &buffer)
        _ = Self.type("x", into: &buffer, from: 60)
        #expect(buffer.currentToken?.text == "x")
    }

    @Test("A pause inside the timeout does not")
    func shortPauseKeepsRun() {
        var buffer = TypingBuffer()
        _ = Self.type("hell", into: &buffer)
        _ = Self.type("o", into: &buffer, from: 2)
        #expect(buffer.currentToken?.text == "hello")
    }

    @Test("An implausibly long run is dropped rather than grown forever")
    func maximumKeystrokesInvalidates() {
        var configuration = TypingBuffer.Configuration()
        configuration.maximumKeystrokes = 5
        var buffer = TypingBuffer(configuration: configuration)
        _ = Self.type("abcdefgh", into: &buffer)
        // The sixth keystroke tripped the cap and cleared the run; the last two
        // started a new one.
        #expect(buffer.pending.count == 2)
    }

    // MARK: - Retention

    @Test("Only the last few finished words are kept")
    func retainsRecentTokens() {
        var configuration = TypingBuffer.Configuration()
        configuration.retainedTokens = 2
        var buffer = TypingBuffer(configuration: configuration)

        for (index, word) in ["one", "two", "three"].enumerated() {
            _ = Self.type(word, into: &buffer, from: Double(index))
            _ = buffer.append(Self.special(Key.space, " ", at: Double(index) + 0.5))
        }
        #expect(buffer.recentTokens.map(\.text) == ["two", "three"])
    }

    @Test("The manual trigger prefers the word in progress")
    func manualTriggerPrefersCurrentToken() {
        var buffer = TypingBuffer()
        _ = Self.type("done", into: &buffer)
        _ = buffer.append(Self.special(Key.space, " ", at: 0.3))
        #expect(buffer.tokenForManualTrigger?.text == "done")

        _ = Self.type("typing", into: &buffer, from: 0.4)
        #expect(buffer.tokenForManualTrigger?.text == "typing")
    }

    @Test("Invalidate drops the word in flight but keeps the finished ones")
    func invalidateKeepsHistory() {
        var buffer = TypingBuffer()
        _ = Self.type("done", into: &buffer)
        _ = buffer.append(Self.special(Key.space, " ", at: 0.3))
        _ = Self.type("typing", into: &buffer, from: 0.4)

        buffer.invalidate()
        #expect(buffer.currentToken == nil)
        #expect(buffer.tokenForManualTrigger?.text == "done")
    }

    @Test("Reset drops everything, so the manual trigger cannot reach another app's text")
    func resetClearsEverything() {
        var buffer = TypingBuffer()
        _ = Self.type("done", into: &buffer)
        _ = buffer.append(Self.special(Key.space, " ", at: 0.3))
        _ = Self.type("typing", into: &buffer, from: 0.4)

        buffer.reset()
        #expect(buffer.currentToken == nil)
        #expect(buffer.tokenForManualTrigger == nil)
        #expect(buffer.recentTokens.isEmpty)
    }

    @Test("Keystrokes survive intact, so the token can be replayed on another layout")
    func tokenCarriesItsKeystrokes() {
        var buffer = TypingBuffer()
        _ = Self.type("Word", into: &buffer)
        let token = buffer.append(Self.special(Key.space, " ", at: 0.5))
        #expect(token?.keystrokes.count == 4)
        #expect(token?.keystrokes.first?.shift == true)
    }
}
