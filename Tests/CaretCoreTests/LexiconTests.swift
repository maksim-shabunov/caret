import Foundation
import Testing
@testable import CaretCore

/// `NSSpellChecker` is a proofreader, not a word validator. Asked something it
/// cannot judge it stays quiet, and quiet reads as approval. Every test here
/// pins down one way that would otherwise have silenced a real correction or
/// waved through a false one.
@Suite("System lexicon", .serialized)
@MainActor
struct LexiconTests {

    let lexicon = SystemSpellLexicon()

    @Test("It knows which languages it can actually answer for")
    func coverage() {
        #expect(lexicon.coverage(for: "en") == .available)
        #expect(lexicon.coverage(for: "ru") == .available)
        // The entire reason the structural rule exists.
        #expect(lexicon.coverage(for: "et") == .unavailable)
    }

    @Test("Ordinary words get ordinary answers")
    func recognisesWords() {
        #expect(lexicon.verdict(for: "hello", language: "en") == .valid)
        #expect(lexicon.verdict(for: "water", language: "en") == .valid)
        #expect(lexicon.verdict(for: "ghbdtn", language: "en") == .invalid)
        #expect(lexicon.verdict(for: "привет", language: "ru") == .valid)
        #expect(lexicon.verdict(for: "ъгт", language: "ru") == .invalid)
    }

    @Test("Capitalisation is not allowed to hide a misspelling")
    func lowercasesBeforeAsking() {
        // Left capitalised, the checker takes these for proper nouns.
        #expect(lexicon.verdict(for: "Ghbdtn", language: "en") == .invalid)
        #expect(lexicon.verdict(for: "Hello", language: "en") == .valid)
    }

    /// The checker approves every one- and two-letter fragment there is.
    @Test("Tokens too short to judge get no verdict", arguments: ["a", "un", "kk", "t", "xq"])
    func shortTokensAreUnknown(_ token: String) {
        #expect(lexicon.verdict(for: token, language: "en") == .unknown)
    }

    /// Left to itself the checker skips the punctuation and approves what is
    /// left, so `]un` reads as valid English — which would have blocked the
    /// correction to `õun` at the first hurdle.
    @Test("Tokens peppered with punctuation get no verdict", arguments: ["]un", "k;;k", "p[[da"])
    func punctuationTokensAreUnknown(_ token: String) {
        #expect(lexicon.verdict(for: token, language: "en") == .unknown)
    }

    /// A dictionary that cannot read the script finds no fault, which is not
    /// the same as finding it correct.
    @Test("A dictionary is not asked about a script it cannot read")
    func scriptMismatchIsUnknown() {
        #expect(lexicon.verdict(for: "руддщ", language: "en") == .unknown)
        #expect(lexicon.verdict(for: "привет", language: "en") == .unknown)
    }

    /// The checker splits at apostrophes and hyphens, then approves any piece
    /// under three letters. `t'na` is the Estonian word `täna` typed on the
    /// wrong layout; taking the checker at its word would mangle it.
    @Test("Contractions count, apostrophes on their own do not")
    func contractionsAreTrustedButFragmentsAreNot() {
        for real in ["don't", "isn't", "we're", "i've", "he'll", "she'd", "i'm", "cat's"] {
            #expect(lexicon.verdict(for: real, language: "en") == .valid, "\(real) was not trusted")
        }
        for fragment in ["t'na", "k'la", "s'na", "t-na", "k-la"] {
            #expect(
                lexicon.verdict(for: fragment, language: "en") == .unknown,
                "\(fragment) was taken for a word"
            )
        }
    }

    @Test("A compound of two real words is still trusted")
    func compoundsAreTrusted() {
        #expect(lexicon.verdict(for: "well-made", language: "en") == .valid)
        #expect(lexicon.verdict(for: "self-made", language: "en") == .valid)
    }

    @Test("Punctuation beside a word is ordinary text and does not change the answer")
    func trimsEdgePunctuation() {
        #expect(lexicon.verdict(for: "hello.", language: "en") == .valid)
        #expect(lexicon.verdict(for: "(hello)", language: "en") == .valid)
        // The one that stops a bracketed word being read as a layout slip.
        #expect(lexicon.verdict(for: "[note]", language: "en") == .valid)
        #expect(lexicon.verdict(for: "list]", language: "en") == .valid)
    }

    @Test("A language with no dictionary produces no verdict at all")
    func missingLanguageIsUnknown() {
        #expect(lexicon.verdict(for: "häälestus", language: "et") == .unknown)
        #expect(lexicon.verdict(for: "köök", language: "et") == .unknown)
    }

    @Test("A regional dictionary stands in for the bare language code")
    func resolvesRegionalVariants() {
        // `pt` is only present as pt_BR / pt_PT on this system.
        #expect(lexicon.coverage(for: "pt") == .available)
    }

    @Test("Asking twice gives the same answer")
    func cachingIsConsistent() {
        let first = lexicon.verdict(for: "hello", language: "en")
        let second = lexicon.verdict(for: "hello", language: "en")
        #expect(first == second)
        #expect(first == .valid)
    }
}
