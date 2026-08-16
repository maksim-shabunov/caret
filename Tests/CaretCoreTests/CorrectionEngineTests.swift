import Foundation
import Testing
@testable import CaretCore

/// The decisions that matter, taken against the dictionaries this machine really
/// has. A regression in the must-not-correct half is worse than a regression in
/// the must-correct half: a missed fix is invisible, a wrong fix is infuriating.
@Suite("Correction decisions", .serialized)
@MainActor
struct CorrectionEngineTests {

    let abc: KeyboardLayout
    let russian: KeyboardLayout
    let estonian: KeyboardLayout
    let all: [KeyboardLayout]

    init() throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russian = try #require(Fixtures.layout(LayoutID.russian))
        estonian = try #require(Fixtures.layout(LayoutID.estonian))
        all = [abc, russian, estonian]
    }

    func systemEngine(minimumLength: Int = 3) -> CorrectionEngine {
        CorrectionEngine(lexicon: SystemSpellLexicon(), minimumLength: minimumLength)
    }

    // MARK: - Must correct

    @Test("Russian typed on the English layout")
    func correctsRussian() throws {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "привет")
        #expect(result.targetLayoutID == LayoutID.russian)
        #expect(result.evidence == .dictionary)
    }

    @Test("English typed on the Russian layout")
    func correctsEnglish() throws {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token("руддщ", on: russian),
            activeLayout: russian,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "hello")
        #expect(result.targetLayoutID == LayoutID.abc)
        #expect(result.evidence == .dictionary)
    }

    @Test("Estonian typed on the English layout, with no Estonian dictionary to ask")
    func correctsEstonianStructurally() throws {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "õun")
        #expect(result.targetLayoutID == LayoutID.estonian)
        // No dictionary vouched for it; the punctuation disappearing did.
        #expect(result.evidence == .structural)
    }

    @Test("Two mistyped vowels in one word")
    func correctsEstonianDoubleVowel() throws {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token("k;;k", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "köök")
        #expect(result.evidence == .structural)
    }

    @Test("An English contraction typed on the Estonian layout")
    func correctsContractionFromEstonian() throws {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token("donät", on: estonian),
            activeLayout: estonian,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "don't")
        #expect(result.targetLayoutID == LayoutID.abc)
        #expect(result.evidence == .dictionary)
    }

    // MARK: - Must not correct

    @Test("A real English word is left alone, whatever else it might spell")
    func leavesEnglishAlone() {
        #expect(systemEngine().evaluate(
            token: Fixtures.token("water", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    @Test("A real Russian word is left alone")
    func leavesRussianAlone() {
        #expect(systemEngine().evaluate(
            token: Fixtures.token("привет", on: russian),
            activeLayout: russian,
            candidateLayouts: all
        ) == nil)
    }

    /// The one that would hurt most. Estonian has no dictionary, so correctly
    /// typed Estonian gets no vote of confidence — it must survive on the fact
    /// that converting it makes things *worse*, not better.
    @Test("Correctly typed Estonian survives having no dictionary")
    func leavesCorrectEstonianAlone() {
        let engine = systemEngine()
        for word in ["häälestus", "köök", "õun", "püüda", "täna", "jõulud"] {
            let proposal = engine.evaluate(
                token: Fixtures.token(word, on: estonian),
                activeLayout: estonian,
                candidateLayouts: all
            )
            #expect(proposal == nil, "Caret tried to 'fix' the Estonian word \(word)")
        }
    }

    /// The layout that happened to be active is not the only language the user
    /// speaks. macOS remembers the input source per app, so Estonian can be
    /// active without anyone having chosen it that minute — and macOS ships no
    /// Estonian dictionary, so nothing could vouch for `her` while `рук` is a
    /// perfectly good Russian word. The user's history has the result.
    @Test("A real word is defended by every language the user types", arguments: [
        "her", "hero", "water", "section", "balance",
    ])
    func defendsWordsFromEveryWatchedLanguage(_ text: String) {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token(text, on: estonian),
            activeLayout: estonian,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret turned \(text) into \(proposal?.corrected ?? "")")
    }

    /// Only each layout's own language, though. A layout advertises everything it
    /// is *capable* of typing, and asking the whole list would find something to
    /// vouch for anything at all.
    @Test("Widening the defence does not silence the corrections")
    func stillCorrectsWithTheWiderDefence() {
        #expect(systemEngine().evaluate(
            token: Fixtures.token("ghbdtn", on: estonian),
            activeLayout: estonian,
            candidateLayouts: all
        )?.corrected == "привет")
    }

    /// An apostrophe is a letter on every layout but the one it was typed on —
    /// `ä` on Estonian, `э` on Russian — so a possessive has a tidy-looking
    /// reading everywhere. The dictionary covered up how often by vouching for
    /// `user's` on its own; what came through were the possessives of every name
    /// and package English has never heard of.
    @Test("A possessive is prose, whatever it spells elsewhere", arguments: [
        "novum's", "section's", "n's", "'ve", "opencode's", "Maksim's", "npm's",
    ])
    func leavesPossessivesAlone(_ text: String) {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret turned \(text) into \(proposal?.corrected ?? "")")
    }

    @Test("Text that belongs to a machine is never touched", arguments: [
        "https://example.com",
        "www.example.com",
        "maksim@example.com",
        "~/Library/Preferences",
        "snake_case_name",
        "camelCaseName",
        "swift6",
        "hi",
    ])
    func leavesMachineTextAlone(_ text: String) {
        // Fed through the keycode route where possible; the guard is what has to
        // fire, before any dictionary work happens.
        let proposal = systemEngine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret tried to correct \(text)")
    }

    /// Brackets and quotes around a real word are ordinary text. Converted to
    /// Estonian they turn into vowels and the result *looks* like a tidier word,
    /// which is precisely the trap the structural rule has to avoid.
    @Test("A bracketed word is punctuation around prose, not a layout slip", arguments: [
        "[note]", "list]", "(idea)", "'quoted'",
    ])
    func leavesBracketedWordsAlone(_ text: String) {
        let proposal = systemEngine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret tried to correct \(text) to \(proposal?.corrected ?? "")")
    }

    /// A layout advertises every language it can type — ABC claims 96 — and a
    /// few of those dictionaries accept any run of Latin letters at all. If the
    /// engine consulted them, `ghbdtn` would read as a real word and Caret would
    /// never correct anything again.
    @Test("Only a layout's own language is consulted")
    func ignoresSecondaryLanguages() {
        #expect(abc.languages.count > 1)
        #expect(abc.primaryLanguage == "en")

        // A dictionary for one of ABC's secondary languages that accepts the
        // gibberish. It must not get a vote.
        let permissive = MockLexicon(
            covered: ["ga", "ru"],
            words: ["ga": ["ghbdtn"], "ru": ["привет"]]
        )
        let proposal = CorrectionEngine(lexicon: permissive).evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal?.corrected == "привет")
    }

    @Test("Gibberish that means nothing anywhere stays as it is")
    func leavesUnrecognisableAlone() {
        // Nonsense in English, nonsense in Russian, and no punctuation for the
        // structural rule to clean up.
        #expect(systemEngine().evaluate(
            token: Fixtures.token("qxzjv", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    @Test("A word the user already reverted is never offered again")
    func respectsSuppression() {
        let engine = systemEngine()
        engine.suppress("ghbdtn")
        #expect(engine.evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)

        engine.clearSuppressions()
        #expect(engine.evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) != nil)
    }

    @Test("Suppression ignores case, because the user reverted the word not the casing")
    func suppressionIsCaseInsensitive() {
        let engine = systemEngine()
        engine.suppress("GHBDTN")
        #expect(engine.isSuppressed("ghbdtn"))
    }

    @Test("Anything typed with a modifier held was a command, not prose")
    func ignoresCommandChords() {
        var token = Fixtures.token("ghbdtn", on: abc)
        token.keystrokes[0].hasCommandChord = true
        #expect(systemEngine().evaluate(
            token: token,
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    @Test("Raising the minimum length silences shorter words")
    func respectsMinimumLength() {
        let short = Fixtures.token("]un", on: abc)
        #expect(systemEngine(minimumLength: 3).evaluate(
            token: short, activeLayout: abc, candidateLayouts: all
        ) != nil)
        #expect(systemEngine(minimumLength: 5).evaluate(
            token: short, activeLayout: abc, candidateLayouts: all
        ) == nil)
    }

    @Test("An empty token is a no-op")
    func ignoresEmptyToken() {
        #expect(systemEngine().evaluate(
            token: Token(keystrokes: [], text: ""),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    // MARK: - Ambiguity

    /// When two layouts each make a case for themselves, Caret has no way to
    /// choose — so it chooses neither. Driven by a mock lexicon because a
    /// genuinely ambiguous pair is hard to find and impossible to rely on.
    @Test("Two plausible layouts cancel each other out")
    func ambiguityProducesSilence() {
        // `]un` on ABC converts to `õun` on Estonian (structurally cleaner) and
        // to `ъгт` on Russian. Teaching the lexicon that `ъгт` is a real Russian
        // word makes both layouts equally plausible.
        let ambiguous = MockLexicon(covered: ["ru"], words: ["ru": ["ъгт"]])
        #expect(CorrectionEngine(lexicon: ambiguous).evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)

        // The same input with only one plausible reading does get corrected —
        // proving the silence above came from the ambiguity and nothing else.
        let unambiguous = MockLexicon(covered: ["ru"], words: ["ru": []])
        let proposal = CorrectionEngine(lexicon: unambiguous).evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal?.corrected == "õun")
    }

    /// Unless the sentence around it can choose. Two readings equally well
    /// evidenced but in different alphabets are no longer a dead heat once it is
    /// known which alphabet the user has been writing in — and the answer follows
    /// the context rather than any preference of Caret's own, which is why both
    /// directions are asserted here.
    @Test("Ambiguity resolves towards the surrounding alphabet")
    func contextBreaksTheTie() {
        let ambiguous = MockLexicon(covered: ["ru"], words: ["ru": ["ъгт"]])
        let engine = CorrectionEngine(lexicon: ambiguous)

        #expect(engine.evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: TypingContext(script: .cyrillic)
        )?.corrected == "ъгт")

        #expect(engine.evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: TypingContext(script: .latin)
        )?.corrected == "õun")
    }

    @Test("A dictionary that rejects the destination blocks the correction")
    func requiresEvidenceForDestination() {
        let lexicon = MockLexicon(covered: ["ru", "en"], words: ["ru": [], "en": []])
        #expect(CorrectionEngine(lexicon: lexicon).evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: [abc, russian]
        ) == nil)
    }

    // MARK: - Manual trigger

    @Test("The manual trigger offers every conversion that changes anything")
    func manualCandidates() {
        let candidates = systemEngine().manualCandidates(
            for: "ghbdtn", from: abc, layouts: all
        )
        // Estonian leaves plain letters untouched, so it offers nothing.
        #expect(candidates.count == 1)
        #expect(candidates.first?.corrected == "привет")
        #expect(candidates.first?.evidence == .manual)
    }

    @Test("The manual trigger ignores the guards, because the user asked")
    func manualIgnoresGuards() {
        // A digit would stop the automatic path dead. Asked for by hand, it goes
        // through.
        let candidates = systemEngine().manualCandidates(
            for: "ghbdtn123", from: abc, layouts: all
        )
        #expect(candidates.contains { $0.corrected == "привет123" })
    }

    @Test("The manual trigger converts a whole phrase")
    func manualHandlesPhrases() {
        let candidates = systemEngine().manualCandidates(
            for: "ghbdtn rfr ltkf", from: abc, layouts: all
        )
        #expect(candidates.contains { $0.corrected == "привет как дела" })
    }
}
