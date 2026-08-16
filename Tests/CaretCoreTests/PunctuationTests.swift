import Foundation
import Testing
@testable import CaretCore

/// What happens to the punctuation around a word.
///
/// Only whitespace ends a token, because `.` and `,` are Cyrillic letters and
/// `;'[]` are Estonian vowels — so `his:` arrives at the engine as one token and
/// every punctuation mark in it has two readings. `his:` is either the English
/// word `his` with a colon, or the keys of `hisÖ` in Estonian; `ghbdtn:` is
/// either `привет` with a colon or `приветЖ`. Both readings cannot be right.
///
/// These are the cases that decide between them. The whole suite exists because
/// Caret shipped for a day preferring the second reading, and turned every colon
/// the user typed into `Ö`.
@Suite("Punctuation round a word", .serialized)
@MainActor
struct PunctuationTests {

    let abc: KeyboardLayout
    let russian: KeyboardLayout
    let estonian: KeyboardLayout
    let all: [KeyboardLayout]
    let models: LanguageModelLibrary

    init() async throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russian = try #require(Fixtures.layout(LayoutID.russian))
        estonian = try #require(Fixtures.layout(LayoutID.estonian))
        all = [abc, russian, estonian]
        models = await Fixtures.models()
    }

    /// The real dictionaries and the real corpora, because the misfire this suite
    /// guards against needed both: the lexicon to have no opinion about `npm`, and
    /// the models to have one about `здарова`.
    func engine() -> CorrectionEngine {
        CorrectionEngine(
            lexicon: SystemSpellLexicon(),
            models: models,
            minimumLength: 3,
            correctsUnknownWords: true,
            sensitivity: .balanced
        )
    }

    func proposal(_ text: String, context: TypingContext = .none) -> CorrectionProposal? {
        engine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: context
        )
    }

    // MARK: - Must not correct

    /// The four rows the user found in their history, plus the neighbours of each.
    /// Every one of these is ordinary English prose that happens to end in a key
    /// Estonian spends on a vowel.
    @Test("An English word with punctuation is prose", arguments: [
        "his:", "this:", "example:", "\"Right", "tea;", "zsh:", "lol:", "brb:",
        "hello,", "hello.", "note;", "yes!", "\"quote", "(idea)",
    ])
    func leavesPunctuatedEnglishAlone(_ text: String) {
        let result = proposal(text)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    /// Harder, because no dictionary vouches for the word either. A name, a
    /// command and a package are all `.invalid` in English, so the only thing
    /// standing between `Synara:` and `SynaraÖ` is the punctuation rule.
    @Test("A word no dictionary knows keeps its punctuation too", arguments: [
        "npm:", "Synara:", "\"Synara", "zsh;", "Caret:", "\"npm",
    ])
    func leavesPunctuatedUnknownWordsAlone(_ text: String) {
        let result = proposal(text)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    /// The most frequent misfire in the user's history, four times over, every
    /// one of them in the middle of English prose. `it.` is two letters and a
    /// full stop; the letters are too short for any dictionary to vouch for, and
    /// `шею` is a Russian word, so nothing stood in the way. Measuring the word
    /// rather than the token is what stops it — and the split reading cannot
    /// rescue it either, since two letters need a Russian sentence around them
    /// before Caret will look at them at all — and `if` is the one that would
    /// survive even then, which `ContextTests` records rather than hides.
    @Test("A two-letter word with punctuation is still a two-letter word", arguments: [
        "it.", "at.", "he.", "we.", "me.", "up.", "or.", "in.", "on.", "so.",
        "no.", "is.", "of.", "hi,", "to!", "an?",
    ])
    func leavesShortWordsWithPunctuationAlone(_ text: String) {
        let result = proposal(text)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    /// A capital in the middle of a word is what a shifted punctuation key looks
    /// like once it has been read as a letter. Nothing Caret produces should ever
    /// contain one, whatever route it took to get there.
    @Test("No correction ever grows a capital in the middle", arguments: [
        "his:", "ghbdtn:", "Synara:", "plfhjdf:", "j,djlrf:", "ckexbkjcm?",
    ])
    func neverProducesInteriorCapitals(_ text: String) {
        guard let corrected = proposal(text)?.corrected else { return }
        let hasInteriorCapital = corrected.dropFirst().contains(where: \.isUppercase)
        #expect(!hasInteriorCapital, "\(text) became \(corrected)")
    }

    /// Units and initials are the one thing one or two letters can be that is
    /// neither a word nor a slip, and the capital is what gives them away. The
    /// price is a lone sentence-opening `Я` typed as `Z` going unfixed, which is
    /// the cheaper mistake.
    @Test("An initial or a unit is left alone", arguments: ["J.", "dB", "mL", "A."])
    func leavesInitialsAlone(_ text: String) {
        let result = proposal(text, context: TypingContext(script: .cyrillic))
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    // MARK: - Must correct

    /// The point of the whole exercise: the word is fixed and the punctuation is
    /// handed back exactly as it was typed.
    @Test("A slip keeps whatever was typed round it", arguments: [
        ("ghbdtn:", "привет:"),
        ("ghbdtn,", "привет,"),
        ("ghbdtn!", "привет!"),
        ("ghbdtn;", "привет;"),
        ("\"ghbdtn", "\"привет"),
        ("j,djlrf:", "обводка:"),
        ("plfhjdf:", "здарова:"),
    ])
    func correctsThroughPunctuation(_ pair: (String, String)) throws {
        let result = try #require(proposal(pair.0), "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        // What gets deleted from the screen has to be what is on the screen.
        #expect(result.original == pair.0)
        #expect(result.targetLayoutID == LayoutID.russian)
    }

    /// And the other way round, because sometimes the punctuation really is the
    /// letter. `.` is `ю` and `?` is `?` on a Russian keyboard, so `ldjqye.` is a
    /// whole word and splitting it would ruin it. The straight reading is tried
    /// first for exactly this reason.
    @Test("Punctuation that is a letter stays a letter", arguments: [
        ("ldjqye.", "двойную"),
        ("ltkf.", "делаю"),
        ("ckexbkjcm?", "случилось?"),
    ])
    func prefersTheWholeWord(_ pair: (String, String)) throws {
        let result = try #require(proposal(pair.0), "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
    }

    /// The Estonian flagship, restated here rather than left to the engine suite:
    /// these are the corrections the punctuation rule is most at risk of killing,
    /// since a leading `]` or an interior `;` is the entire evidence for them.
    @Test("An Estonian vowel typed as punctuation is still caught", arguments: [
        ("]un", "õun"), ("k;;k", "köök"), ("t;na", "töna"),
    ])
    func stillCorrectsEstonian(_ pair: (String, String)) throws {
        let result = try #require(proposal(pair.0), "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        #expect(result.targetLayoutID == LayoutID.estonian)
        #expect(result.evidence == .structural)
    }

    /// A word short enough to need the context rescue, with punctuation after it.
    /// The comma is `б` in Russian, so the straight reading of `z,` is `яб` —
    /// nonsense — and the split reading is the one that has to survive. This is
    /// most of what the rescue is for in practice: a lone `я` in the middle of a
    /// sentence has a comma after it far more often than not.
    @Test("A one-letter word keeps the punctuation after it", arguments: [
        ("z,", "я,"), ("z.", "я."), ("z!", "я!"), ("z?", "я?"),
        ("z;", "я;"), ("\"z", "\"я"), ("(z)", "(я)"),
    ])
    func rescuesShortWordWithPunctuation(_ pair: (String, String)) throws {
        let cyrillic = TypingContext(script: .cyrillic)
        let result = try #require(proposal(pair.0, context: cyrillic), "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        #expect(result.original == pair.0)
        #expect(result.evidence == .context)
    }

    /// The punctuation is set aside, not ignored — what is left still has to be
    /// nothing but letters. A digit or a hyphen next to a letter is a version
    /// number, a range or an identifier, and none of them is prose.
    @Test("Setting punctuation aside does not admit anything else", arguments: [
        "z1", "z-", "1z", "z_", "z/", "z1.", "z-,",
    ])
    func splitDoesNotAdmitOtherCharacters(_ text: String) {
        let result = proposal(text, context: TypingContext(script: .cyrillic))
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    // MARK: - The rule underneath

    /// `withoutEdgePunctuation` is what stops the structural rule counting a colon
    /// as dirt. The two absences matter as much as the trims: `ü` is `[` and `ä` is
    /// `'` on an ABC keyboard, so an Estonian word can genuinely begin with either.
    @Test("Only the punctuation prose puts round a word is set aside", arguments: [
        ("his:", "his"),
        ("\"Right", "Right"),
        ("(idea)", "idea"),
        ("hello...", "hello"),
        ("]un", "]un"),      // `õun` — a leading bracket is a vowel, not a quote
        ("[ks", "[ks"),      // `üks`
        ("'ra", "'ra"),      // `ära`
        ("k;;k", "k;;k"),    // interior punctuation is never an edge
    ])
    func trimsOnlyOrdinaryPunctuation(_ pair: (String, String)) {
        #expect(StructuralAnalyzer.withoutEdgePunctuation(pair.0) == pair.1)
    }

    /// A token that is nothing but punctuation has no word in it to correct, and a
    /// token with no punctuation round it has nothing to set aside.
    @Test("There has to be a word in the middle", arguments: ["...", ":", "\"\"", "hello"])
    func refusesTokensWithNothingToSplit(_ text: String) {
        #expect(SplitToken(Fixtures.token(text, on: abc)) == nil)
    }

    /// The split has to be made of the same keystrokes as the token it came from,
    /// or replaying them through another layout would reconstruct a different word.
    @Test("The core keeps the keys that typed it")
    func splitKeepsKeystrokes() throws {
        let token = Fixtures.token("\"ghbdtn:", on: abc)
        let split = try #require(SplitToken(token))

        #expect(split.prefix == "\"")
        #expect(split.suffix == ":")
        #expect(split.core.text == "ghbdtn")
        #expect(split.core.keystrokes.map(\.text).joined() == "ghbdtn")
        #expect(split.core.keystrokes.count == 6)
        #expect(split.core.keystrokes.map(\.keyCode) == Array(token.keystrokes[1..<7]).map(\.keyCode))
    }
}

/// The reading the structural rule cannot see: one wrong key.
///
/// Stray punctuation is read everywhere else as the fingerprint of a layout
/// slip, and in a short word it is one — prose does not put a bracket two
/// characters into `]un`. In a long word it is just as likely to be a finger
/// landing next door, `;` being one key from `l`, and `remarkab;e` came back as
/// `remarkaböe`.
@Suite("A wrong key, or a wrong layout", .serialized)
@MainActor
struct TypoTests {

    let abc: KeyboardLayout
    let all: [KeyboardLayout]
    let models: LanguageModelLibrary

    init() async throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        all = [
            abc,
            try #require(Fixtures.layout(LayoutID.russian)),
            try #require(Fixtures.layout(LayoutID.estonian)),
        ]
        models = await Fixtures.models()
    }

    func proposal(_ text: String, priority: [String] = []) -> CorrectionProposal? {
        CorrectionEngine(
            lexicon: SystemSpellLexicon(),
            models: models,
            sensitivity: .balanced,
            layoutPriority: priority
        ).evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: TypingContext(script: .latin)
        )
    }

    /// An English word with one key wrong, which is what these are. Every one is
    /// a clean word in Estonian once the stray is read as a vowel, so the
    /// punctuation rule has nothing to say against any of them. `he;;o` carries
    /// two wrong keys and is caught all the same, because the test is what the
    /// neighbouring key spells rather than how many slid.
    @Test("One wrong key in a long English word", arguments: [
        "remarkab;e", "possib;e", "simp;e", "tab;e", "wor;d", "peop;e", "artic;e",
        "he;;o", "wou;d", "fie;d", "who;e", "sing;e", "midd;e",
    ])
    func leavesTyposAlone(_ text: String) {
        let result = proposal(text)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    /// And what must survive it. Nothing beside any of these strays spells an
    /// English word: `]` reaches only `[`, `'` only `;`, and `k;;k` reaches
    /// `kllk`. That last one is why only the same row is searched — allow the
    /// row above and `;` also reaches `o`, making `kook`, and Estonian loses
    /// `köök` to an English word it never meant.
    @Test("An Estonian vowel typed as punctuation is still caught", arguments: [
        ("]un", "õun"), ("k;;k", "köök"), ("t;na", "töna"), ("[ks", "üks"),
        ("p[[da", "püüda"), ("h''lestus", "häälestus"),
    ])
    func stillCorrectsEstonian(_ pair: (String, String)) throws {
        let result = try #require(proposal(pair.0), "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        #expect(result.evidence == .structural)
    }

    /// The claim is about the language the text was typed in, so it stands
    /// against every layout at once. Made per layout instead — and only where the
    /// user ranks the source language higher — it silenced the reading it was
    /// aimed at and handed the word to the next layout along: with Russian above
    /// English, `tab;e` came back as `ефижу` rather than `taböe`.
    @Test("A typo is a typo whoever else lays claim to it", arguments: [
        [] as [String],
        [LayoutID.russian, LayoutID.abc, LayoutID.estonian],
        [LayoutID.estonian, LayoutID.abc, LayoutID.russian],
        [LayoutID.abc, LayoutID.russian, LayoutID.estonian],
    ])
    func holdsWhateverTheOrder(_ priority: [String]) {
        let result = proposal("tab;e", priority: priority)
        #expect(result == nil, "Caret turned tab;e into \(result?.corrected ?? "")")
        #expect(proposal("remarkab;e", priority: priority) == nil)
        // And the order never costs a correction that should happen.
        #expect(proposal("]un", priority: priority)?.corrected == "õun")
    }

    /// Russian text typed on an English keyboard also arrives carrying a stray —
    /// `,` is `б` — and has to survive, which it does because what is left is not
    /// English by any measure.
    @Test("The other direction is untouched", arguments: [
        ("j,djlrf", "обводка"), ("xnj,s", "чтобы"), (",skj", "было"),
    ])
    func leavesRussianSlipsAlone(_ pair: (String, String)) {
        #expect(proposal(pair.0)?.corrected == pair.1)
    }
}

/// Where the keys physically sit, which is what tells a slid finger from a
/// slipped layout.
@Suite("Neighbouring keys")
struct KeyNeighbourTests {

    /// Semicolon, the key this whole rule exists for: one right of `l`, one left
    /// of the quote.
    @Test("A key knows what is either side of it")
    func findsNeighbours() {
        #expect(KeyGeometry.sameRowNeighbours(of: 41) == [37, 39])
    }

    /// Deliberately not the diagonals `areAdjacent` accepts. `;` touches `o` and
    /// `p` on the row above, and admitting them turns `k;;k` into `kook`.
    @Test("The row above is not a neighbour")
    func staysOnItsOwnRow() {
        #expect(!KeyGeometry.sameRowNeighbours(of: 41).contains(31))  // o
        #expect(!KeyGeometry.sameRowNeighbours(of: 41).contains(35))  // p
        #expect(KeyGeometry.areAdjacent(41, 31))
    }

    /// The ends of a row have one neighbour, and a key Caret does not model has
    /// none — which is what stops `]un` being repaired into anything at all.
    @Test("The ends of a row, and keys that are not on it")
    func handlesEdges() {
        #expect(KeyGeometry.sameRowNeighbours(of: 30) == [33])   // ] — only [
        #expect(KeyGeometry.sameRowNeighbours(of: 50) == [18])   // ` — only 1
        #expect(KeyGeometry.sameRowNeighbours(of: 999).isEmpty)
    }
}
