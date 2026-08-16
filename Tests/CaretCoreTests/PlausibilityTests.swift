import Foundation
import Testing
@testable import CaretCore

/// The character models, measured against the corpora Caret actually ships.
///
/// The numbers in these tests are not arbitrary. Every threshold in `Sensitivity`
/// was chosen by scoring real examples through these exact word lists, so the
/// assertions here are the record of that measurement — if the corpora or the
/// smoothing change, these are what say so.
@Suite("Word shape", .serialized)
@MainActor
struct CharacterModelTests {

    let russian: CharacterModel
    let english: CharacterModel

    init() async throws {
        let library = await Fixtures.models()
        russian = try #require(library.model(for: "ru"))
        english = try #require(library.model(for: "en"))
    }

    @Test("Both corpora are present and large enough to learn from")
    func corporaAreShipped() {
        #expect(russian.trainingWords > 20_000)
        #expect(english.trainingWords > 10_000)
        #expect(russian.deviation > 0)
        #expect(english.deviation > 0)
    }

    /// Calibration sanity. `plausibility` is defined as standard deviations from
    /// an ordinary word, so an ordinary word has to come out near zero — that is
    /// what makes a Russian score and an English score comparable at all.
    @Test("A word from the corpus scores like an ordinary word")
    func corpusWordsScoreNearZero() throws {
        for word in ["привет", "спасибо", "человек", "работа", "который"] {
            let score = russian.plausibility(of: word)
            #expect(abs(score) < 3, "\(word) scored \(score)")
        }
        for word in ["hello", "because", "keyboard", "morning", "another"] {
            let score = english.plausibility(of: word)
            #expect(abs(score) < 3, "\(word) scored \(score)")
        }
    }

    /// The point of the whole exercise. These four are the user's own examples,
    /// and the first assertion is the one that makes the second mean anything:
    /// none of them is in the corpus, so the model is scoring words it has never
    /// seen.
    ///
    /// Measured: здарова +0.2, обводка −1.4, здаровк −2.3, чупеп −4.3.
    @Test("Slang and typos absent from the corpus still read as words", arguments: [
        "здарова",   // slang for здорово
        "обводка",   // a real word the keyboard lexicon simply lacks
        "здаровк",   // здарова with the last letter fumbled
        "чупеп",
    ])
    func unseenWordsScoreLikeWords(_ word: String) throws {
        let corpus = try #require(BundledWordLists().words(forLanguage: "ru"))
        #expect(
            !Set(corpus).contains(word),
            "\(word) is in the corpus, so this test proves nothing about unseen words"
        )
        let score = russian.plausibility(of: word)
        #expect(score > -5.5, "\(word) scored \(score), below the balanced floor")
    }

    /// The other half. Letters Russian never puts together must score far worse
    /// than words it has never seen — otherwise the model is measuring nothing.
    ///
    /// `ъыьъы` matters because a dictionary rejects it *exactly* as firmly as it
    /// rejects `здарова`. Shape is the only thing that tells them apart.
    @Test("Sequences the language does not build score far below", arguments: [
        "ъыьъы", "ячсмит", "ярглщм", "щшжэъь",
    ])
    func impossibleSequencesScoreFarBelow(_ word: String) {
        let score = russian.plausibility(of: word)
        #expect(score < -5.5, "\(word) scored \(score), which is word-like")
    }

    /// What a layout slip looks like from the inside: text that is hopeless in
    /// the language it was typed in.
    @Test("Text typed on the wrong layout is hopeless where it was typed", arguments: [
        "plfhjdf", "j,djlrf", "xegtg", "ghbdtn",
    ])
    func layoutSlipsScoreBadlyInEnglish(_ text: String) {
        let score = english.plausibility(of: StructuralAnalyzer.trimmed(text))
        #expect(score < -4, "\(text) scored \(score) as English, which is too respectable")
    }

    /// A misspelling is still shaped like the word it was meant to be, which is
    /// why the shape rule cannot be used to *find* typos — only to recognise that
    /// mistyped text still belongs to a language.
    @Test("English misspellings remain plainly English")
    func misspellingsRemainEnglish() {
        for word in ["recieve", "definately", "seperate", "occured"] {
            let score = english.plausibility(of: word)
            #expect(score > -4, "\(word) scored \(score), so it no longer looks English")
        }
    }

    @Test("An empty string scores as unremarkable rather than crashing")
    func emptyStringIsNeutral() {
        #expect(russian.plausibility(of: "") == 0)
    }

    /// Characters the corpus never contained get the smoothed floor, not a trap
    /// door. A comma inside a word should be improbable, not fatal.
    @Test("Unknown characters are improbable, not undefined")
    func unknownCharactersAreFinite() {
        let score = russian.plausibility(of: "при,вет")
        #expect(score.isFinite)
        #expect(score < russian.plausibility(of: "привет"))
    }

    @Test("Training refuses a word list too small to learn anything from")
    func refusesTinyCorpus() {
        #expect(CharacterModel.train(language: "xx", words: ["one", "two"]) == nil)
        #expect(CharacterModel.train(language: "xx", words: []) == nil)
    }

    @Test("Training is deterministic, because the alphabet comes out sorted")
    func trainingIsDeterministic() throws {
        let words = (0..<200).map { "word\($0 % 26)" + String(Character(UnicodeScalar(97 + $0 % 26)!)) }
        let first = try #require(CharacterModel.train(language: "xx", words: words))
        let second = try #require(CharacterModel.train(language: "xx", words: words))
        #expect(first.score("worda") == second.score("worda"))
    }
}

/// Resolving a layout's language onto a word list that exists.
@Suite("Model library", .serialized)
@MainActor
struct LanguageModelLibraryTests {

    @Test("Regional variants fall back to the base language")
    func resolvesRegionalVariants() async {
        let library = await Fixtures.models()
        #expect(library.hasModel(for: "en"))
        #expect(library.hasModel(for: "ru"))
    }

    /// Estonian is the honest gap. macOS ships no Estonian lexicon of any kind,
    /// so there was nothing to harvest and there is nothing to train. Caret says
    /// so rather than guessing — Estonian slips are caught by their punctuation
    /// instead, which is what they actually look like.
    @Test("A language with no word list has no model")
    func estonianHasNoModel() async {
        let library = await Fixtures.models()
        #expect(!library.hasModel(for: "et"))
        #expect(library.model(for: "et") == nil)
    }

    @Test("Before warming, every model is absent and nothing breaks")
    func coldLibraryIsSilent() {
        let library = LanguageModelLibrary()
        #expect(!library.hasModel(for: "ru"))
        #expect(library.model(for: "ru") == nil)
    }

    @Test("Warming twice trains once")
    func warmingIsIdempotent() async {
        let counter = CountingWordLists()
        let library = LanguageModelLibrary(source: counter)
        await library.warm(languages: ["ru"])
        await library.warm(languages: ["ru"])
        #expect(counter.requests == 1)
        #expect(library.hasModel(for: "ru"))
    }
}

/// A word list source that records how often it was asked.
final class CountingWordLists: WordListSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requests: Int {
        lock.withLock { count }
    }

    var availableLanguages: [String] { ["ru"] }

    func words(forLanguage language: String) -> [String]? {
        lock.withLock { count += 1 }
        // Enough to clear the training floor, and shaped like Russian syllables.
        let syllables = ["ра", "то", "ни", "ко", "ве", "ла", "ди", "мо", "ся", "ба"]
        var words: [String] = []
        for first in syllables {
            for second in syllables {
                words.append(first + second)
            }
        }
        return words
    }
}

/// Fingers walking across the board, which letter statistics cannot see.
@Suite("Keyboard runs")
@MainActor
struct KeyGeometryTests {

    let abc: KeyboardLayout

    init() throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
    }

    /// Each of these reads as a plausible Russian syllable once converted —
    /// `hjkl` becomes `ролд`, `zxcvbn` becomes `ячсмит` — so the letters cannot
    /// be trusted to reject them. The geometry can.
    @Test("A path traced across the keyboard is recognised", arguments: [
        "hjkl", "qwerty", "asdfgh", "zxcvbn", "wasd", "fghj", "poiu",
    ])
    func detectsRuns(_ text: String) {
        #expect(KeyGeometry.isRun(keystrokes: Fixtures.type(text, on: abc)))
    }

    @Test("Real words are not runs", arguments: [
        "ghbdtn", "plfhjdf", "j,djlrf", "hello", "water", "keyboard", "morning",
    ])
    func realWordsAreNotRuns(_ text: String) {
        #expect(!KeyGeometry.isRun(keystrokes: Fixtures.type(text, on: abc)))
    }

    /// Three adjacent keys happen by accident in ordinary words — `ass`, `тре` —
    /// so three is not enough to conclude anything.
    @Test("Fewer than four keys is never a run")
    func shortSequencesAreNotRuns() {
        #expect(!KeyGeometry.isRun(keystrokes: Fixtures.type("asd", on: abc)))
        #expect(!KeyGeometry.isRun([]))
    }

    @Test("Unmapped keycodes are not adjacent to anything")
    func unknownKeysAreNotAdjacent() {
        #expect(!KeyGeometry.areAdjacent(999, 0))
        #expect(!KeyGeometry.isRun([999, 998, 997, 996]))
    }
}

/// The rule itself: both sides judged separately, then a margin on top.
@Suite("Shape rule", .serialized)
@MainActor
struct PlausibilityRuleTests {

    let abc: KeyboardLayout
    let russianLayout: KeyboardLayout
    let russian: CharacterModel
    let english: CharacterModel

    init() async throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russianLayout = try #require(Fixtures.layout(LayoutID.russian))
        let library = await Fixtures.models()
        russian = try #require(library.model(for: "ru"))
        english = try #require(library.model(for: "en"))
    }

    func verdict(
        _ original: String,
        _ candidate: String,
        sensitivity: Sensitivity = .balanced
    ) -> Result<PlausibilityRule.Verdict, PlausibilityRule.Refusal> {
        PlausibilityRule(sensitivity: sensitivity).evaluate(
            original: original,
            candidate: candidate,
            keystrokes: Fixtures.type(original, on: abc),
            sourceModel: english,
            targetModel: russian
        )
    }

    @Test("The user's examples are accepted", arguments: [
        ("plfhjdf", "здарова"),
        ("j,djlrf", "обводка"),
        ("xegtg", "чупеп"),
        ("plfhjdr", "здаровк"),
    ])
    func acceptsSlangAndTypos(_ pair: (String, String)) throws {
        let result = verdict(pair.0, pair.1)
        guard case .success = result else {
            Issue.record("refused \(pair.0) → \(pair.1): \(result)")
            return
        }
    }

    @Test("Keyboard mashing is refused on geometry", arguments: [
        "hjkl", "qwerty", "asdfgh", "zxcvbn",
    ])
    func refusesKeyboardRuns(_ text: String) throws {
        let candidate = try #require(
            LayoutMapper.translate(keystrokes: Fixtures.type(text, on: abc), to: russianLayout)
        )
        #expect(verdict(text, candidate) == .failure(.keyboardRun))
    }

    /// Proof that the geometry check is load-bearing rather than belt-and-braces.
    /// With the keystrokes withheld, so the run cannot be seen, the letters alone
    /// accept both of these: `hjkl` reads as `ролд` (−1.2) and `zxcvbn` as
    /// `ячсмит` (−5.6), which are shaped like ordinary Russian. And because both
    /// are such hopeless English, the gap between the two readings comes out
    /// *wider* than for any genuine correction Caret makes — so no threshold, in
    /// either direction, separates them from real slips. The only thing that
    /// gives them away is that the fingers walked in a line.
    ///
    /// Measured at `eager`. At `balanced` the candidate floor happens to catch
    /// `ячсмит` by 0.08 of a standard deviation, which is luck and not a defence:
    /// `ролд` clears that floor comfortably at every setting.
    @Test("The letters alone would accept a keyboard run", arguments: [
        ("hjkl", "ролд"), ("zxcvbn", "ячсмит"),
    ])
    func lettersAloneWouldAcceptRuns(_ pair: (String, String)) {
        let blind = PlausibilityRule(sensitivity: .eager).evaluate(
            original: pair.0,
            candidate: pair.1,
            keystrokes: [],
            sourceModel: english,
            targetModel: russian
        )
        guard case .success = blind else {
            Issue.record("expected the letters alone to accept \(pair.1), got \(blind)")
            return
        }
    }

    @Test("A conversion that is not word-like is refused however bad the original is")
    func refusesUnwordlikeCandidate() {
        // `zhukov` → `ярещм`. Nonsense both ways; the conversion has to earn its
        // place on its own merits, and it has none.
        let result = verdict("zhukov", "яреыщм")
        guard case .failure(.candidateNotWordLike) = result else {
            Issue.record("expected candidateNotWordLike, got \(result)")
            return
        }
    }

    /// An artificial pair, because the point is the guard and not the conversion:
    /// even offered a flawless Russian word, the rule refuses when the typed text
    /// reads perfectly well as English. Somebody who writes `keyboard` meant
    /// `keyboard`.
    @Test("Text that reads fine where it was typed is left alone")
    func refusesWhenOriginalIsFine() {
        let result = verdict("keyboard", "привет")
        guard case .failure(.originalLooksFine) = result else {
            Issue.record("expected originalLooksFine, got \(result)")
            return
        }
    }

    @Test("Short tokens carry too little shape to judge")
    func refusesShortTokens() {
        #expect(verdict("brb", "или") == .failure(.tooShort))
        #expect(verdict("xyz", "чня") == .failure(.tooShort))
    }

    /// Estonian, again. Missing a model is a refusal with a name, not a silent
    /// nil that could be mistaken for "measured and rejected".
    @Test("A missing model refuses rather than guesses")
    func refusesWithoutModel() {
        let rule = PlausibilityRule(sensitivity: .balanced)
        let keystrokes = Fixtures.type("plfhjdf", on: abc)
        #expect(
            rule.evaluate(
                original: "plfhjdf", candidate: "здарова", keystrokes: keystrokes,
                sourceModel: english, targetModel: nil
            ) == .failure(.noModel(language: "target"))
        )
        #expect(
            rule.evaluate(
                original: "plfhjdf", candidate: "здарова", keystrokes: keystrokes,
                sourceModel: nil, targetModel: russian
            ) == .failure(.noModel(language: "source"))
        )
    }

    /// The settings earn their place here: the three levels have to differ on
    /// something real, in a predictable direction.
    @Test("Sensitivity widens what is accepted, monotonically")
    func sensitivityIsOrdered() {
        // `dfot` → `ваще`, very common Russian slang and a weak-scoring word.
        let cases = ["plfhjdf": "здарова", "xegtg": "чупеп", "dfot": "ваще"]
        var accepted: [Sensitivity: Int] = [:]
        for level in Sensitivity.allCases {
            accepted[level] = cases.count {
                if case .success = verdict($0.key, $0.value, sensitivity: level) { return true }
                return false
            }
        }
        #expect(accepted[.cautious]! <= accepted[.balanced]!)
        #expect(accepted[.balanced]! <= accepted[.eager]!)
        // And they are genuinely different settings, not three names for one.
        #expect(accepted[.eager]! > accepted[.cautious]!)
    }

    @Test("Cautious wants a thoroughly ordinary word")
    func cautiousDeclinesWeakerReadings() {
        // Accepted at balanced, refused at cautious: `чупеп` is word-shaped but
        // not word-ordinary.
        if case .success = verdict("xegtg", "чупеп", sensitivity: .cautious) {
            Issue.record("cautious accepted чупеп")
        }
        guard case .success = verdict("xegtg", "чупеп", sensitivity: .balanced) else {
            Issue.record("balanced refused чупеп")
            return
        }
    }

    @Test("Surrounding punctuation is not part of the word being scored")
    func trimsPunctuationBeforeScoring() throws {
        // The trailing comma belongs to the sentence. Scoring it as part of the
        // word would drag a perfectly good correction below the floor.
        let bare = try #require(verdict("plfhjdf", "здарова").score)
        let punctuated = try #require(verdict("plfhjdf", "здарова.").score)
        #expect(abs(bare - punctuated) < 0.001)
    }
}

private extension Result where Success == PlausibilityRule.Verdict {
    var score: Double? {
        if case .success(let verdict) = self { return verdict.candidateScore }
        return nil
    }
}

/// End to end: the engine deciding, with the real models and a lexicon that has
/// heard of nothing.
///
/// A blank lexicon is not a convenience here, it is the point. `здарова`,
/// `обводка` and every typo are genuinely words no dictionary will vouch for, so
/// a test that let the dictionary rules answer would be testing the wrong tier.
/// With every verdict coming back `.invalid`, only shape can produce a
/// correction — and only shape can prevent one.
@Suite("Shape-based corrections", .serialized)
@MainActor
struct ShapeCorrectionTests {

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

    func engine(
        sensitivity: Sensitivity = .balanced,
        correctsUnknownWords: Bool = true
    ) -> CorrectionEngine {
        CorrectionEngine(
            lexicon: Fixtures.blankLexicon(),
            models: models,
            correctsUnknownWords: correctsUnknownWords,
            sensitivity: sensitivity
        )
    }

    // MARK: - Must correct

    @Test("Slang no dictionary carries", arguments: [
        ("plfhjdf", "здарова"),
        ("j,djlrf", "обводка"),
        ("xegtg", "чупеп"),
    ])
    func correctsSlang(_ pair: (String, String)) throws {
        let proposal = engine().evaluate(
            token: Fixtures.token(pair.0, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        let result = try #require(proposal, "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        #expect(result.targetLayoutID == LayoutID.russian)
        #expect(result.evidence == .plausibility)
    }

    /// The user's fourth example, and the harder one: `здаровк` is not a word in
    /// any language and never will be. It is a misspelling of a slang spelling.
    /// Still recognisably Russian, and still worth fixing.
    @Test("A typo inside slang is still recognisably Russian")
    func correctsTypoWithinSlang() throws {
        let proposal = engine().evaluate(
            token: Fixtures.token("plfhjdr", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "здаровк")
        #expect(result.evidence == .plausibility)
    }

    /// The same thing pointing the other way: a Russian layout left active while
    /// typing English. `цфкз` is what `warp` becomes, and it is the Cyrillic that
    /// reads as nonsense here — sixteen deviations of it — while the English is
    /// ordinary. Shape does not care which language it is arguing for.
    @Test("English typed on the Russian layout", arguments: [
        ("цфкз", "warp"),
        ("тщзу", "nope"),
        ("цфттф", "wanna"),
        ("вгттщ", "dunno"),
        ("пщттф", "gonna"),
        ("нуфр", "yeah"),
    ])
    func correctsIntoEnglish(_ pair: (String, String)) throws {
        let proposal = engine().evaluate(
            token: Fixtures.token(pair.0, on: russian),
            activeLayout: russian,
            candidateLayouts: all
        )
        let result = try #require(proposal, "Caret left \(pair.0) alone")
        #expect(result.corrected == pair.1)
        #expect(result.targetLayoutID == LayoutID.abc)
        #expect(result.evidence == .plausibility)
    }

    /// And where a dictionary does know the word, it answers first and the shape
    /// tier is never reached. `warp` is ordinary English, so the reverse direction
    /// was already covered before shape existed — this is the tier below saying so.
    @Test("A dictionary answers the reverse direction too")
    func dictionaryHandlesTheReverseDirection() throws {
        let lexicon = MockLexicon(covered: ["en", "ru"], words: ["en": ["warp"]])
        let proposal = CorrectionEngine(lexicon: lexicon, models: models).evaluate(
            token: Fixtures.token("цфкз", on: russian),
            activeLayout: russian,
            candidateLayouts: all
        )
        let result = try #require(proposal)
        #expect(result.corrected == "warp")
        #expect(result.evidence == .dictionary)
    }

    // MARK: - Must not correct

    /// The failure that would be unforgivable: mangling correctly typed Russian.
    /// The blank lexicon gives these words no protection at all, so shape is
    /// carrying the whole load.
    @Test("Correctly typed Russian is safe on shape alone", arguments: [
        "привет", "здарова", "обводка", "спасибо", "работа", "чувак", "движуха",
    ])
    func leavesRussianAlone(_ word: String) {
        let proposal = engine().evaluate(
            token: Fixtures.token(word, on: russian),
            activeLayout: russian,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret 'corrected' \(word) to \(proposal?.corrected ?? "")")
    }

    /// English words the dictionary here has been told nothing about. Real prose
    /// must not become Cyrillic just because no dictionary spoke up for it.
    @Test("Unvouched-for English stays English", arguments: [
        "keyboard", "morning", "because", "recieve", "definately", "async", "nottingham",
    ])
    func leavesEnglishAlone(_ word: String) {
        let proposal = engine().evaluate(
            token: Fixtures.token(word, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret 'corrected' \(word) to \(proposal?.corrected ?? "")")
    }

    @Test("Keyboard mashing is left exactly as typed", arguments: [
        "hjkl", "qwerty", "asdfgh", "zxcvbn", "wasd",
    ])
    func leavesMashingAlone(_ text: String) {
        let proposal = engine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret 'corrected' \(text) to \(proposal?.corrected ?? "")")
    }

    /// The guard that keeps the reverse direction honest, and its price. `recieve`
    /// mistyped on the Russian layout comes out as `кусшуму`, which is shaped like
    /// perfectly ordinary Russian — so Caret leaves it, and the misspelling stays
    /// Cyrillic. Refusing to touch text that reads well where it stands is what
    /// protects real Russian from being converted; this is the same rule, costing
    /// something.
    @Test("Text that reads fine as Russian is left as Russian")
    func respectsPlausibleCyrillic() {
        let proposal = engine().evaluate(
            token: Fixtures.token("кусшуму", on: russian),
            activeLayout: russian,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret 'corrected' кусшуму to \(proposal?.corrected ?? "")")
    }

    @Test("Gibernish that is nonsense in every language is left alone", arguments: [
        "qxzjv", "zhukov", "xkcd", "brb", "lol",
    ])
    func leavesGibberishAlone(_ text: String) {
        let proposal = engine().evaluate(
            token: Fixtures.token(text, on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
        #expect(proposal == nil, "Caret 'corrected' \(text) to \(proposal?.corrected ?? "")")
    }

    // MARK: - Wiring

    @Test("Turning the setting off restores dictionary-only behaviour")
    func settingDisablesTheTier() {
        #expect(engine(correctsUnknownWords: false).evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    /// Every dictionary-only behaviour has to be exactly as it was. Absent
    /// models, the shape rule cannot fire at all.
    @Test("Without models the engine behaves as it did before")
    func withoutModelsNothingChanges() {
        let engine = CorrectionEngine(lexicon: Fixtures.blankLexicon(), models: nil)
        #expect(engine.evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    /// When two layouts both offer something, the better-evidenced one wins.
    /// A dictionary that recognises the word settles the matter against a
    /// judgement about the word's shape; without that ordering, adding the shape
    /// tier would have turned confident corrections into ambiguous silence
    /// wherever a second Cyrillic layout happened to be installed.
    ///
    /// Needs two layouts that can both produce Cyrillic, which this machine has
    /// only one of, so the second is a copy of Russian wearing another language's
    /// code.
    @Test("Dictionary evidence outranks shape")
    func dictionaryOutranksShape() throws {
        let ukrainian = KeyboardLayout(
            id: "test.layout.Ukrainian",
            localizedName: "Ukrainian",
            languages: ["uk"],
            plain: russian.plain,
            shifted: russian.shifted
        )
        // Ukrainian vouches for the word; Russian rejects it and has only shape
        // to go on.
        let lexicon = MockLexicon(covered: ["en", "ru", "uk"], words: ["uk": ["здарова"]])
        let proposal = CorrectionEngine(lexicon: lexicon, models: models).evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: [abc, russian, ukrainian]
        )
        let result = try #require(proposal)
        #expect(result.corrected == "здарова")
        #expect(result.evidence == .dictionary)
        #expect(result.targetLayoutID == ukrainian.id)
    }

    /// The same shape, one rank down: two layouts that can only offer shape
    /// cannot break the tie, so Caret stays quiet.
    ///
    /// The second layout is Russian with one key moved, so that it produces
    /// `здарота` where Russian produces `здарова` — two different words, both
    /// shaped like Russian, with nothing but shape behind either. Hand-built,
    /// because the two Cyrillic layouts that would really disagree like this are
    /// not installed on this machine, and a test that needed them would be a test
    /// that only ran somewhere else.
    @Test("Two shape-only readings cancel out")
    func competingShapeReadingsCancel() throws {
        let variant = try #require(shiftedVariant(of: russian))
        #expect(engine().evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: [abc, russian, variant]
        ) == nil)

        // And the same input against the variant alone is corrected, which is
        // what makes the silence above attributable to the ambiguity.
        let proposal = engine().evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: [abc, variant]
        )
        #expect(proposal?.corrected == "здарота")
    }

    /// A copy of `layout` with the `d` and `n` keys exchanged. Real layouts differ
    /// from one another in exactly this way — Russian and Russian – PC are a few
    /// keys apart — so the result is an odd layout rather than an impossible one.
    private func shiftedVariant(of layout: KeyboardLayout) -> KeyboardLayout? {
        let dKey: UInt16 = 2, nKey: UInt16 = 45
        guard let d = layout.plain[dKey], let n = layout.plain[nKey] else { return nil }
        var plain = layout.plain
        plain[dKey] = n
        plain[nKey] = d
        return KeyboardLayout(
            id: "test.layout.RussianVariant",
            localizedName: "Russian Variant",
            languages: ["ru"],   // so the same model answers for both
            plain: plain,
            shifted: layout.shifted
        )
    }

    @Test("The shape rule never overrides a word that is valid where it stands")
    func respectsTheOriginalVeto() {
        // The lexicon vouches for the typed text. Nothing downstream may argue.
        let lexicon = MockLexicon(covered: ["en"], words: ["en": ["plfhjdf"]])
        #expect(CorrectionEngine(lexicon: lexicon, models: models).evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    @Test("The existing guards still run first")
    func guardsStillApply() {
        // A digit anywhere, and Caret never reaches the models.
        #expect(engine().evaluate(
            token: Fixtures.token("plfhjdf2", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }

    @Test("A reverted correction stays reverted")
    func suppressionAppliesToShapeCorrections() {
        let engine = engine()
        engine.suppress("plfhjdf")
        #expect(engine.evaluate(
            token: Fixtures.token("plfhjdf", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ) == nil)
    }
}
