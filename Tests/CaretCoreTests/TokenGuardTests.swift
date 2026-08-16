import Foundation
import Testing
@testable import CaretCore

@Suite("Token guard")
struct TokenGuardTests {

    func skip(_ token: String, minimumLength: Int = 3) -> SkipReason? {
        TokenGuard.reasonToSkip(token, minimumLength: minimumLength)
    }

    @Test("Ordinary words pass through", arguments: [
        "hello", "привет", "õun", "well-made", "Hello",
    ])
    func allowsWords(_ token: String) {
        #expect(skip(token) == nil, "\(token) was skipped")
    }

    /// A possessive or a contraction is prose, and the apostrophe holding it
    /// together is a letter on every other layout: `'` is `ä` on Estonian and
    /// `э` on Russian, so `novum's` reads as `novumäs` and `'ve` as `эму`. Both
    /// happened. The dictionary hid how often by vouching for `user's` on its
    /// own, so what got through were the possessives of every name, brand and
    /// package English has never heard of.
    @Test("A possessive or contraction is prose", arguments: [
        "don't", "novum's", "section's", "n's", "'ve", "they're", "we've",
        "I'll", "won't", "Maksim's", "opencode's",
    ])
    func skipsContractions(_ token: String) {
        #expect(skip(token) == .looksLikeContraction, "\(token) was not skipped")
    }

    /// What Estonian pays for it, which is almost nothing. `ä` is the apostrophe
    /// key on an ABC keyboard, so `täna` arrives as `t'na` and `ära` as `'ra` —
    /// and neither `na` nor `ra` is a thing English contracts to.
    @Test("An Estonian vowel typed as an apostrophe is not a contraction", arguments: [
        "t'na", "'ra", "p'rast", "k'si", "h''lestus",
    ])
    func allowsEstonianApostrophes(_ token: String) {
        #expect(skip(token) != .looksLikeContraction, "\(token) was mistaken for a contraction")
    }

    /// The important one. `]un` is `õun` typed on the wrong layout, and the
    /// leading bracket is the entire signal — trimming it before measuring
    /// length would drop the token below the threshold and hide the slip.
    @Test("A layout slip is not mistaken for machine text", arguments: [
        "]un", "k;;k", "donät", "h''lestus", "p[[da",
    ])
    func allowsLayoutSlips(_ token: String) {
        #expect(skip(token) == nil, "\(token) was skipped")
    }

    @Test("Addresses are left alone", arguments: [
        "https://example.com", "http://x.dev", "www.example.com",
        "maksim@example.com", "@mention",
    ])
    func skipsAddresses(_ token: String) {
        #expect(skip(token) == .looksLikeAddress)
    }

    @Test("Paths are left alone", arguments: ["~/Library", "src/main", "C:\\Windows"])
    func skipsPaths(_ token: String) {
        #expect(skip(token) == .looksLikePath)
    }

    @Test("Code is left alone", arguments: [
        "snake_case", "camelCase", "value=x", "a|b", "list(item)", "dict{key}",
        "a*b", "half%off", "x^y", "a&b", "tilde~here", "less<than", "hash#tag",
        "cost$here",
    ])
    func skipsIdentifiers(_ token: String) {
        #expect(skip(token) == .looksLikeIdentifier)
    }

    @Test("Anything with a digit is left alone", arguments: ["swift6", "v2beta", "abc123"])
    func skipsDigits(_ token: String) {
        #expect(skip(token) == .containsDigit)
    }

    @Test("Text with no letters at all is not a word", arguments: ["...", "---", "!?"])
    func skipsLetterlessText(_ token: String) {
        #expect(skip(token) == .noLetters)
    }

    @Test("Short words carry too little signal")
    func skipsShortWords() {
        #expect(skip("hi") == .tooShort)
        #expect(skip("hi", minimumLength: 2) == nil)
        #expect(skip("hey") == nil)
    }

    /// Length is the word's, not the token's. `it.` is two letters and a full
    /// stop, and two letters is below every threshold there is — but measured
    /// whole it came to three, cleared this guard, and met a Russian dictionary
    /// perfectly happy to call `шею` a word.
    @Test("A full stop is no part of the word", arguments: [
        "it.", "at.", "he.", "we.", "up.", "or.", "hi,", "\"of", "(me)", "so!",
    ])
    func measuresTheWordRatherThanTheToken(_ token: String) {
        #expect(skip(token) == .tooShort, "\(token) was not skipped")
    }

    /// And the punctuation that is not ordinary still counts, which is the whole
    /// of the Estonian case: `]un` is three characters only if the bracket is
    /// one of them.
    @Test("Punctuation prose does not use is part of the word", arguments: [
        "]un", "[ks", "'ra", "k;;k",
    ])
    func keepsUnusualPunctuationInTheCount(_ token: String) {
        #expect(skip(token) != .tooShort, "\(token) was called too short")
    }

    @Test("A digit outranks the other reasons, because it is the cheapest certainty")
    func digitsTakePrecedence() {
        #expect(skip("user1@example.com") == .containsDigit)
    }

    @Test("Camel case needs an actual case change, not just capitals")
    func camelCaseDetection() {
        #expect(TokenGuard.isCamelCase("fooBar"))
        #expect(TokenGuard.isCamelCase("aB"))
        #expect(!TokenGuard.isCamelCase("Hello"))
        #expect(!TokenGuard.isCamelCase("HELLO"))
        #expect(!TokenGuard.isCamelCase("hello"))
        #expect(!TokenGuard.isCamelCase("A"))
    }
}

@Suite("Structural analysis")
struct StructuralAnalyzerTests {

    @Test("A clean word is letters, optionally joined", arguments: [
        "hello", "õun", "don't", "well-made", "привет", "hello.",
    ])
    func recognisesCleanWords(_ token: String) {
        #expect(StructuralAnalyzer.isCleanWord(token))
    }

    @Test("Anything peppered with symbols is not", arguments: [
        "k;;k", "a=b", "x_y", "q", "123",
    ])
    func rejectsUncleanWords(_ token: String) {
        #expect(!StructuralAnalyzer.isCleanWord(token))
    }

    /// `isCleanWord` asks about a token's *shape* once ordinary edge punctuation
    /// is set aside, so a bracketed `]un` and an apostrophe-laden `h''lestus`
    /// both read as word-shaped. That is deliberate — the same leniency is what
    /// lets `don't` and `hello.` through. Telling a slip from a real word is
    /// `nonLetterCount`'s job, not this one's.
    @Test("Word shape and layout-slip detection are separate questions")
    func cleanWordIsAboutShapeOnly() {
        #expect(StructuralAnalyzer.isCleanWord("]un"))
        #expect(StructuralAnalyzer.isCleanWord("h''lestus"))

        // The discrimination happens here instead.
        #expect(StructuralAnalyzer.nonLetterCount("]un") > StructuralAnalyzer.nonLetterCount("õun"))
        #expect(StructuralAnalyzer.isCleanerThan("õun", original: "]un"))
        #expect(!StructuralAnalyzer.isCleanerThan("]un", original: "õun"))
    }

    @Test("Non-letters are counted wherever they fall")
    func countsNonLetters() {
        #expect(StructuralAnalyzer.nonLetterCount("õun") == 0)
        #expect(StructuralAnalyzer.nonLetterCount("]un") == 1)   // leading
        #expect(StructuralAnalyzer.nonLetterCount("k;;k") == 2)  // interior
        #expect(StructuralAnalyzer.nonLetterCount("un[") == 1)   // trailing
    }

    @Test("Latin and Cyrillic in one token never happens by accident")
    func detectsMixedScripts() {
        #expect(StructuralAnalyzer.mixesScripts("приvet"))
        #expect(!StructuralAnalyzer.mixesScripts("привет"))
        #expect(!StructuralAnalyzer.mixesScripts("hello"))
        // Estonian diacritics are Latin, not a second script.
        #expect(!StructuralAnalyzer.mixesScripts("häälestus"))
        // Punctuation and emoji are not a script for this purpose.
        #expect(!StructuralAnalyzer.mixesScripts("don't🙂"))
    }

    @Test("A conversion that removes punctuation is an improvement")
    func recognisesImprovement() {
        #expect(StructuralAnalyzer.isCleanerThan("õun", original: "]un"))
        #expect(StructuralAnalyzer.isCleanerThan("köök", original: "k;;k"))
        #expect(StructuralAnalyzer.isCleanerThan("häälestus", original: "h''lestus"))
    }

    @Test("A conversion that adds punctuation is not")
    func rejectsRegression() {
        #expect(!StructuralAnalyzer.isCleanerThan("]un", original: "õun"))
        #expect(!StructuralAnalyzer.isCleanerThan("h''lestus", original: "häälestus"))
    }

    @Test("Swapping one clean word for another proves nothing on its own")
    func rejectsSidewaysMove() {
        // Both sides are clean, so there is no structural evidence either way.
        // Only a dictionary can decide this one.
        #expect(!StructuralAnalyzer.isCleanerThan("hello", original: "руддщ"))
    }

    @Test("A mixed-script original is evidence enough by itself")
    func mixedScriptCountsAsEvidence() {
        // Switching layout mid-word leaves both scripts in the token. Replaying
        // the keystrokes gives one clean script back.
        #expect(StructuralAnalyzer.isCleanerThan("привет", original: "приvet"))
    }

    @Test("Leading and trailing punctuation is ordinary and gets trimmed")
    func trimsEdges() {
        #expect(StructuralAnalyzer.trimmed("(hello)") == "hello")
        #expect(StructuralAnalyzer.trimmed("\"quoted\",") == "quoted")
        #expect(StructuralAnalyzer.trimmed("hello") == "hello")
        #expect(StructuralAnalyzer.trimmed("...") == "")
    }
}
