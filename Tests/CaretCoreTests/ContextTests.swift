import Foundation
import Testing
@testable import CaretCore

/// Which alphabet a passage is written in.
@Suite("Surrounding script")
@MainActor
struct DominantScriptTests {

    @Test("A sentence answers with the alphabet it is written in")
    func readsPlainSentences() {
        #expect(Script.dominant(in: "привет как дела") == .cyrillic)
        #expect(Script.dominant(in: "the quick brown fox") == .latin)
    }

    @Test("Punctuation, spaces and digits are not letters")
    func ignoresNonLetters() {
        #expect(Script.dominant(in: "привет, 12345!") == .cyrillic)
        #expect(Script.dominant(in: "— «текст» …") == .cyrillic)
    }

    /// Four letters is not a sentence. Without this the very first word typed
    /// after switching app would start dictating what the next one meant.
    @Test("Too few letters to be sure of anything")
    func refusesShortPassages() {
        #expect(Script.dominant(in: "прив") == nil)
        #expect(Script.dominant(in: "") == nil)
        #expect(Script.dominant(in: "12345 !!!") == nil)
        #expect(Script.dominant(in: "abcde") == .latin)
    }

    /// The distinction that matters most: a Russian sentence with an English word
    /// in it is still a Russian sentence, but a passage genuinely half in each is
    /// nobody's, and answers so.
    @Test("One foreign word does not change the answer")
    func toleratesForeignWords() {
        #expect(Script.dominant(in: "надо открыть терминал") == .cyrillic)
        #expect(Script.dominant(in: "надо открыть ok") == .cyrillic)
    }

    @Test("A passage split between two alphabets belongs to neither")
    func refusesMixedPassages() {
        #expect(Script.dominant(in: "привет hello") == nil)
        #expect(Script.dominant(in: "код на python") == nil)
    }

    @Test("An alphabet Caret does not model is not an answer")
    func refusesUnmodelledScripts() {
        #expect(Script.dominant(in: "你好世界你好") == nil)
        #expect(Script.dominant(in: "こんにちは") == nil)
    }

    /// Used by the tie-break, where the "passage" is one candidate word.
    @Test("The minimum can be lowered to judge a single word")
    func acceptsSingleWords() {
        #expect(Script.dominant(in: "я", minimumLetters: 1) == .cyrillic)
        #expect(Script.dominant(in: "z", minimumLetters: 1) == .latin)
    }
}

/// The sliding window: thirty characters, one app, one minute.
@Suite("Recent text")
@MainActor
struct ContextWindowTests {

    let app = "com.apple.TextEdit"
    let other = "com.apple.Safari"
    let russian = "com.apple.keylayout.Russian"
    let abc = "com.apple.keylayout.ABC"

    @Test("Only the last few characters are kept")
    func discardsTheOldest() {
        let window = ContextWindow(capacity: 10)
        window.note("abcdefghij", app: app, at: 0)
        #expect(window.text == "abcdefghij")
        window.note("klm", app: app, at: 1)
        #expect(window.text == "defghijklm")
    }

    @Test("Text stays put while the same app keeps being typed in")
    func accumulatesWithinOneApp() {
        let window = ContextWindow()
        window.note("привет ", app: app, at: 0)
        window.note("как ", app: app, at: 1)
        #expect(window.text == "привет как ")
        #expect(window.context(app: app, at: 2).script == .cyrillic)
    }

    /// The user's first condition. Text in another window is somebody else's
    /// sentence, and switching back does not make it theirs again.
    @Test("Switching app drops everything")
    func forgetsOnAppSwitch() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, at: 0)
        window.note("hi", app: other, at: 1)
        #expect(window.text == "hi")
        // And returning does not bring it back.
        window.note("!", app: app, at: 2)
        #expect(window.text == "!")
    }

    @Test("Another app's text is never answered with")
    func refusesToSpeakForAnotherApp() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, at: 0)
        #expect(window.context(app: other, at: 1) == .none)
        #expect(window.context(app: nil, at: 1) == .none)
    }

    /// The user's third condition, and the one they had to ask for twice.
    /// Reaching for the layout key is someone saying which language they are
    /// about to write in; the Russian they wrote a second earlier must not go on
    /// speaking for the English they are typing now.
    @Test("Switching layout drops everything")
    func forgetsOnLayoutSwitch() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, layout: russian, at: 0)
        #expect(window.context(app: app, layout: russian, at: 1).script == .cyrillic)

        // Asked about the new layout, before a single key has been typed on it.
        #expect(window.context(app: app, layout: abc, at: 1) == .none)

        // And typing on it starts a new sentence rather than joining the old one.
        window.note("of ", app: app, layout: abc, at: 2)
        #expect(window.text == "of ")
        #expect(window.context(app: app, layout: abc, at: 3) == .none)
    }

    /// What it costs, stated plainly: one word. A layout change nobody chose is
    /// followed by the ordinary rules fixing whole words, and the window fills
    /// with the corrections rather than the typos — so the sentence can speak
    /// again almost at once.
    @Test("The window refills as soon as there is text on the new layout")
    func recoversAfterALayoutSwitch() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, layout: russian, at: 0)
        window.note("привет ", app: app, layout: abc, at: 1)
        #expect(window.context(app: app, layout: abc, at: 2).script == .cyrillic)
    }

    /// The user's second condition. A minute's silence ends a train of thought.
    @Test("A pause of more than a minute drops everything")
    func forgetsAfterIdling() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, at: 100)
        #expect(window.context(app: app, at: 159).script == .cyrillic)
        #expect(window.context(app: app, at: 161) == .none)

        window.note("hi", app: app, at: 200)
        #expect(window.text == "hi")
    }

    @Test("A pause shorter than the timeout changes nothing")
    func keepsTextAcrossShortPauses() {
        let window = ContextWindow()
        window.note("привет ", app: app, at: 0)
        window.note("как дела", app: app, at: 59)
        #expect(window.text == "привет как дела")
        #expect(window.context(app: app, at: 60).script == .cyrillic)
    }

    @Test("An empty window has nothing to say")
    func startsSilent() {
        let window = ContextWindow()
        #expect(window.text.isEmpty)
        #expect(window.context(app: app, at: 0) == .none)
    }

    @Test("Clearing leaves nothing behind")
    func clearsCompletely() {
        let window = ContextWindow()
        window.note("привет как дела", app: app, at: 0)
        window.clear()
        #expect(window.text.isEmpty)
        #expect(window.context(app: app, at: 1) == .none)
    }

    @Test("Too little text to judge is not an answer")
    func staysSilentUntilThereIsEnough() {
        let window = ContextWindow()
        window.note("да ", app: app, at: 0)
        #expect(window.context(app: app, at: 1) == .none)
    }
}

/// The rule that lets a sentence speak for a word too short to speak for itself.
///
/// A blank lexicon throughout, as in the shape tests: no dictionary has anything
/// useful to say about one or two letters, and `SystemSpellLexicon` refuses to
/// pass its answer on at this length for exactly that reason.
@Suite("Corrections from context", .serialized)
@MainActor
struct ContextCorrectionTests {

    let abc: KeyboardLayout
    let russian: KeyboardLayout
    let all: [KeyboardLayout]
    let models: LanguageModelLibrary

    let cyrillic = TypingContext(script: .cyrillic)
    let latin = TypingContext(script: .latin)

    init() async throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russian = try #require(Fixtures.layout(LayoutID.russian))
        all = [abc, try #require(Fixtures.layout(LayoutID.estonian)), russian]
        models = await Fixtures.models()
    }

    func engine(
        sensitivity: Sensitivity = .balanced,
        usesContext: Bool = true
    ) -> CorrectionEngine {
        CorrectionEngine(
            lexicon: Fixtures.blankLexicon(),
            models: models,
            usesContext: usesContext,
            sensitivity: sensitivity
        )
    }

    /// Judges `text` as though it were typed on `layout` in the middle of a
    /// sentence written in `context`.
    func proposal(
        _ text: String,
        on layout: KeyboardLayout,
        context: TypingContext,
        sensitivity: Sensitivity = .balanced
    ) -> CorrectionProposal? {
        engine(sensitivity: sensitivity).evaluate(
            token: Fixtures.token(text, on: layout),
            activeLayout: layout,
            candidateLayouts: all,
            context: context
        )
    }

    // MARK: - Must correct

    /// The user's example, exactly: a Russian line, a comma, and then `z` where
    /// `я` was meant. Nothing about the letter itself can say which was intended;
    /// the sentence around it can.
    @Test("A lone letter in a Russian sentence")
    func rescuesLoneLetter() throws {
        let result = try #require(proposal("z", on: abc, context: cyrillic))
        #expect(result.corrected == "я")
        #expect(result.evidence == .context)
        #expect(result.targetLayoutID == LayoutID.russian)
    }

    @Test("Two-letter Russian words, which are most of the short ones", arguments: [
        ("yf", "на"), ("yt", "не"), ("gj", "по"), ("jn", "от"),
        ("lj", "до"), ("bp", "из"), ("pf", "за"), ("nj", "то"),
        ("jy", "он"), ("rf", "ка"),
    ])
    func rescuesTwoLetterWords(_ pair: (String, String)) throws {
        let result = try #require(
            proposal(pair.0, on: abc, context: cyrillic),
            "Caret left \(pair.0) alone"
        )
        #expect(result.corrected == pair.1)
        #expect(result.evidence == .context)
    }

    /// The other direction, which has to work just as well: a Russian layout left
    /// active in the middle of an English sentence.
    @Test("Short English words in an English sentence", arguments: [
        ("щл", "ok"), ("ьу", "me"), ("ьн", "my"), ("вщ", "do"), ("гз", "up"),
    ])
    func rescuesIntoEnglish(_ pair: (String, String)) throws {
        let result = try #require(
            proposal(pair.0, on: russian, context: latin),
            "Caret left \(pair.0) alone"
        )
        #expect(result.corrected == pair.1)
        #expect(result.evidence == .context)
        #expect(result.targetLayoutID == LayoutID.abc)
    }

    /// Two layouts that both produce Cyrillic are not in disagreement — they
    /// propose the same letter. Only genuinely different readings are a tie.
    @Test("Layouts that agree on the letter are not a conflict")
    func identicalReadingsAreNotATie() throws {
        let ukrainian = KeyboardLayout(
            id: "test.layout.Ukrainian",
            localizedName: "Ukrainian",
            languages: ["ru"],
            plain: russian.plain,
            shifted: russian.shifted
        )
        let result = try #require(engine().evaluate(
            token: Fixtures.token("z", on: abc),
            activeLayout: abc,
            candidateLayouts: [abc, russian, ukrainian],
            context: cyrillic
        ))
        #expect(result.corrected == "я")
    }

    // MARK: - Must not correct

    /// Without a sentence to speak for it, a short word is untouchable. This is
    /// every case where the window has been dropped: a fresh app, a click, a
    /// minute's pause, or the setting switched off.
    @Test("No context, no correction")
    func silentWithoutContext() {
        #expect(proposal("z", on: abc, context: .none) == nil)
        #expect(proposal("yf", on: abc, context: .none) == nil)
    }

    @Test("A lone letter in an English sentence is left alone")
    func respectsEnglishContext() {
        #expect(proposal("z", on: abc, context: latin) == nil)
        #expect(proposal("yf", on: abc, context: latin) == nil)
    }

    /// Correctly typed short words, in the language of the sentence they are in.
    /// The alphabet already matches, so there is nothing to consider.
    @Test("Short words already in the right alphabet", arguments: [
        "я", "на", "не", "по", "от", "до", "из", "за", "то", "он",
    ])
    func leavesCorrectShortWordsAlone(_ word: String) {
        #expect(proposal(word, on: russian, context: cyrillic) == nil)
    }

    /// The hazard this rule runs: short English words genuinely meant as English,
    /// inside a Russian sentence. Shape refuses almost all of them — `ok` reads as
    /// `щл`, thirteen deviations worse than `ok` is as English.
    @Test("Short English words inside a Russian sentence", arguments: [
        "ok", "hi", "no", "so", "to", "in", "on", "is", "it", "at",
        "my", "me", "we", "he", "by", "do", "go", "up", "or", "of",
        "an", "as", "am", "us", "be", "id", "os", "pc", "ai", "ha",
    ])
    func leavesEnglishShortWordsAlone(_ word: String) {
        let result = proposal(word, on: abc, context: cyrillic)
        #expect(result == nil, "Caret turned \(word) into \(result?.corrected ?? "")")
    }

    /// The two that get through, recorded rather than hidden. `if` reads as `ша`
    /// and `tv` as `ем`, both shapely enough in Russian to clear the margin, and
    /// the English model thinks little of either as English (−7.6 and −19.0). Only
    /// the sentence being Russian puts them in reach at all; in an English one
    /// both are refused, which is where they are overwhelmingly typed.
    @Test("The known false positives, and their one saving grace", arguments: ["if", "tv"])
    func documentsKnownFalsePositives(_ word: String) {
        #expect(proposal(word, on: abc, context: cyrillic) != nil)
        #expect(proposal(word, on: abc, context: latin) == nil)
    }

    @Test("Anything that is not purely letters is not a word", arguments: [
        "z1", "z-", "1z", "z ", "z_", "z/",
    ])
    func requiresLettersOnly(_ text: String) {
        #expect(proposal(text, on: abc, context: cyrillic) == nil)
    }

    /// With one exception, and it is the punctuation prose ordinarily puts round a
    /// word. `я,` is far commoner in real writing than a bare `я`, and refusing it
    /// made the rescue useless in the middle of a sentence — so the comma is set
    /// aside, the letter is judged alone, and the comma is handed back untouched.
    /// The full account of that split lives in `PunctuationTests`.
    @Test("Ordinary punctuation is set aside, not counted against the word", arguments: [
        ("z,", "я,"), ("z.", "я."), ("z!", "я!"), ("z?", "я?"), ("\"z", "\"я"),
    ])
    func setsOrdinaryPunctuationAside(_ pair: (String, String)) {
        #expect(proposal(pair.0, on: abc, context: cyrillic)?.corrected == pair.1)
        // Still only ever in a Russian sentence. In an English one a lone `z` is a
        // lone `z`, whatever follows it.
        #expect(proposal(pair.0, on: abc, context: latin) == nil)
    }

    /// Units and abbreviations are the one thing two letters can be that is
    /// neither a word nor a slip.
    @Test("Units keep their capital", arguments: ["dB", "mL", "kB", "mV"])
    func leavesUnitsAlone(_ text: String) {
        #expect(proposal(text, on: abc, context: cyrillic) == nil)
    }

    /// The tier is bounded at two letters. From three up, the ordinary rules have
    /// enough to work with and are far more careful — `brb` stays `brb` even in the
    /// middle of a Russian line.
    @Test("Three letters is not the short path's business", arguments: [
        "brb", "lol", "xyz", "omg",
    ])
    func doesNotReachOrdinaryWords(_ text: String) {
        #expect(proposal(text, on: abc, context: cyrillic) == nil)
    }

    // MARK: - Wiring

    @Test("Turning the setting off silences the tier entirely")
    func settingDisablesTheTier() {
        #expect(engine(usesContext: false).evaluate(
            token: Fixtures.token("z", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: cyrillic
        ) == nil)
    }

    @Test("Without models there is nothing to measure and nothing happens")
    func needsModels() {
        #expect(CorrectionEngine(lexicon: Fixtures.blankLexicon(), models: nil).evaluate(
            token: Fixtures.token("z", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: cyrillic
        ) == nil)
    }

    @Test("A reverted letter stays reverted")
    func suppressionApplies() {
        let engine = engine()
        engine.suppress("z")
        #expect(engine.evaluate(
            token: Fixtures.token("z", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: cyrillic
        ) == nil)
    }

    @Test("A modifier chord is a command, not a letter")
    func ignoresChords() {
        var keystrokes = Fixtures.type("z", on: abc)
        keystrokes[0].hasCommandChord = true
        #expect(engine().evaluate(
            token: Token(keystrokes: keystrokes, text: "z", trailing: " "),
            activeLayout: abc,
            candidateLayouts: all,
            context: cyrillic
        ) == nil)
    }

    /// The setting has to mean something here too, in the same direction as it
    /// does everywhere else: `вы` and `ты` are real words with a narrower gap than
    /// `на` has, and only the widest setting reaches them.
    @Test("Sensitivity widens what the sentence can rescue")
    func sensitivityIsOrdered() {
        #expect(proposal("ds", on: abc, context: cyrillic, sensitivity: .cautious) == nil)
        #expect(proposal("ds", on: abc, context: cyrillic, sensitivity: .balanced) == nil)
        #expect(proposal("ds", on: abc, context: cyrillic, sensitivity: .eager)?.corrected == "вы")
    }
}

/// The other direction: a sentence speaking *against* a correction.
///
/// The dictionary rule asks only whether the destination is a word, and for
/// short strings the answer is too often yes — `NSSpellChecker` will call `шву`
/// and `уду` Russian, and no English dictionary has heard of `ide` or `ele`.
/// Nothing about those letters can settle it, so the sentence has to.
///
/// The real dictionaries and the real corpora throughout, because the whole
/// question is what the shipped ones actually say.
@Suite("Corrections the sentence refuses", .serialized)
@MainActor
struct ContextVetoTests {

    let abc: KeyboardLayout
    let russian: KeyboardLayout
    let all: [KeyboardLayout]
    let models: LanguageModelLibrary

    let cyrillic = TypingContext(script: .cyrillic)
    let latin = TypingContext(script: .latin)

    init() async throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russian = try #require(Fixtures.layout(LayoutID.russian))
        all = [abc, russian, try #require(Fixtures.layout(LayoutID.estonian))]
        models = await Fixtures.models()
    }

    func engine(usesContext: Bool = true, sensitivity: Sensitivity = .balanced) -> CorrectionEngine {
        CorrectionEngine(
            lexicon: SystemSpellLexicon(),
            models: models,
            usesContext: usesContext,
            sensitivity: sensitivity
        )
    }

    func proposal(
        _ text: String,
        on layout: KeyboardLayout,
        context: TypingContext,
        usesContext: Bool = true
    ) -> CorrectionProposal? {
        engine(usesContext: usesContext).evaluate(
            token: Fixtures.token(text, on: layout),
            activeLayout: layout,
            candidateLayouts: all,
            context: context
        )
    }

    // MARK: - Must not correct

    /// The user's history, twice over for `IDE`. Acronyms and clipped words that
    /// no dictionary knows, sitting in plain English prose, each of which the
    /// Russian dictionary was willing to accept the conversion of.
    @Test("A word at home in the sentence it landed in", arguments: [
        "IDE", "ide", "ele", "her", "hero", "ise", "ame", "ore", "ade",
    ])
    func leavesWordsTheSentenceVouchesFor(_ text: String) {
        let result = proposal(text, on: abc, context: latin)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    /// And the same the other way round, since nothing here is about English.
    @Test("Russian prose defends a Russian-shaped word too", arguments: [
        "поре", "лове", "тени",
    ])
    func leavesRussianWordsTheSentenceVouchesFor(_ text: String) {
        let result = proposal(text, on: russian, context: cyrillic)
        #expect(result == nil, "Caret turned \(text) into \(result?.corrected ?? "")")
    }

    // MARK: - Must still correct

    /// The flagship, and the reason this is safe. Someone typing Russian on an
    /// English layout is writing into a window that fills with Cyrillic —
    /// corrections go into it, not the text they replaced — while the layout
    /// under their hands says Latin. Layout and sentence disagree, so the veto
    /// never engages, whatever the sentence turns out to be.
    @Test("A layout slip is untouched in any sentence", arguments: [
        ("ghbdtn", "привет"), ("ckexbkjcm", "случилось"), ("gjcthtlbyt", "посередине"),
    ])
    func neverBlocksASlip(_ pair: (String, String)) {
        for context in [TypingContext.none, latin, cyrillic] {
            #expect(
                proposal(pair.0, on: abc, context: context)?.corrected == pair.1,
                "Caret left \(pair.0) alone in \(context.script.map { "\($0)" } ?? "no") context"
            )
        }
    }

    /// The run in the user's history that this most had to survive: a whole
    /// English sentence typed on the Russian layout. By the second word the
    /// window is Latin while the layout is Cyrillic, which is exactly the
    /// disagreement that keeps the veto out of the way.
    @Test("An English sentence typed on the Russian layout", arguments: [
        ("еру", "the"), ("дшлу", "like"), ("ершы", "this"), ("зфпу", "page"),
        ("рфму", "have"), ("фтн", "any"), ("лштв", "kind"), ("щлфн", "okay"),
    ])
    func neverBlocksTheOtherDirection(_ pair: (String, String)) {
        #expect(proposal(pair.0, on: russian, context: latin)?.corrected == pair.1)
    }

    /// `еру` is the closest call in the corpus and worth recording exactly.
    /// Measured against the shipped Russian list it scores −4.007, which is
    /// under the balanced threshold by seven thousandths — so at the default
    /// setting Russian prose does *not* defend it and it still becomes `the`.
    /// One notch more cautious and it does. Nothing else in the user's history
    /// comes within four deviations of a boundary; this is the whole of the
    /// uncertainty in one word.
    @Test("The closest call, decided by the setting rather than by luck")
    func documentsTheClosestCall() {
        #expect(proposal("еру", on: russian, context: latin)?.corrected == "the")
        #expect(proposal("еру", on: russian, context: cyrillic)?.corrected == "the")

        let cautious = engine(sensitivity: .cautious).evaluate(
            token: Fixtures.token("еру", on: russian),
            activeLayout: russian,
            candidateLayouts: all,
            context: cyrillic
        )
        #expect(cautious == nil)
    }

    // MARK: - Wiring

    /// Without a sentence there is nothing to defend a word with, which is the
    /// behaviour every one of these had before the window existed.
    @Test("No context, no veto")
    func silentWithoutContext() {
        #expect(proposal("ide", on: abc, context: .none)?.corrected == "шву")
    }

    @Test("Turning the setting off gives the sentence no say")
    func settingDisablesTheVeto() {
        #expect(proposal("ide", on: abc, context: latin, usesContext: false)?.corrected == "шву")
    }

    /// The setting has to mean something here too, and in the same direction it
    /// means everywhere else: the more cautious Caret is, the readier it is to
    /// believe a word belongs where it was typed. Asserted on the threshold
    /// itself rather than through the engine, because a word that happens to sit
    /// between two of these thresholds *and* has a conversion worth making is a
    /// coincidence, and a test built on one proves nothing about the ordering.
    @Test("Sensitivity widens what the sentence can defend")
    func sensitivityIsOrdered() async throws {
        let english = try #require(models.model(for: "en"))
        func defends(_ sensitivity: Sensitivity, _ word: String) -> Bool {
            PlausibilityRule(sensitivity: sensitivity)
                .readsAsOrdinaryWord(word, model: english)
        }

        // Ordinary enough for anything (−0.4), and gibberish by any measure
        // (−9.5). Every setting has to agree about both.
        for sensitivity in Sensitivity.allCases {
            #expect(defends(sensitivity, "ide"))
            #expect(!defends(sensitivity, "ghbdtn"))
        }

        // And in between, the settings differ in the stated order. `nginx` is
        // −4.9 and `api` −3.6, so each falls out one notch later than the last.
        #expect(defends(.cautious, "nginx"))
        #expect(!defends(.balanced, "nginx"))

        #expect(defends(.balanced, "api"))
        #expect(!defends(.eager, "api"))
    }

    /// A model it was never given cannot defend anything, which is how Estonian
    /// behaves and has to: macOS ships nothing to learn it from.
    @Test("No model, no defence")
    func needsAModel() {
        #expect(!PlausibilityRule(sensitivity: .balanced).readsAsOrdinaryWord("ide", model: nil))
    }
}
