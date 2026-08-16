import Foundation

/// What convinced Caret that a correction was right.
public enum CorrectionEvidence: Sendable, Equatable {
    /// A dictionary recognised the converted text and rejected the original.
    case dictionary
    /// No dictionary covers the destination language, but the original carried
    /// punctuation that the conversion cleans up. This is the Estonian path.
    case structural
    /// No dictionary recognises the conversion, but its letters are shaped like
    /// the language it would belong to and the typed text is not. This is what
    /// catches slang and misspellings — the words a dictionary has never heard
    /// of and never will.
    case plausibility
    /// The word is too short to mean anything on its own, but it is written in a
    /// different alphabet from the sentence it landed in. This is the lone `z` in
    /// the middle of a Russian line, which was meant to be `я`.
    case context
    /// The user asked for it by hand. No evidence required.
    case manual

    /// How much weight to give this, when two layouts both offer a correction.
    ///
    /// Only one distinction is drawn, and deliberately only one: a claim that the
    /// destination reading is a real word beats a judgement about the shape of
    /// its letters. `dictionary` and `structural` are peers — one has a
    /// dictionary's word for it, the other has punctuation turning into letters,
    /// and neither is obviously the better witness. Two of those together stay
    /// ambiguous, exactly as they were before shape was ever measured.
    ///
    /// `context` sits with them only for tidiness. It can never meet any of the
    /// others: it is the only rule that runs on words of one or two letters, and
    /// the only rule that does not.
    var rank: Int {
        switch self {
        case .dictionary, .structural, .context: 2
        case .plausibility: 1
        case .manual: 0
        }
    }
}

/// A correction Caret is prepared to make.
public struct CorrectionProposal: Sendable, Equatable {
    public var original: String
    public var corrected: String
    public var targetLayoutID: String
    public var targetLayoutName: String
    public var evidence: CorrectionEvidence

    public init(
        original: String,
        corrected: String,
        targetLayoutID: String,
        targetLayoutName: String,
        evidence: CorrectionEvidence
    ) {
        self.original = original
        self.corrected = corrected
        self.targetLayoutID = targetLayoutID
        self.targetLayoutName = targetLayoutName
        self.evidence = evidence
    }
}

/// Decides whether a token was typed on the wrong keyboard layout.
///
/// The bias is heavily towards silence. A correction happens only when the
/// evidence points one way and one way only; anything ambiguous is dropped.
@MainActor
public final class CorrectionEngine {
    private let lexicon: LexiconProvider

    /// Character models per language. Absent means the shape-based rule is off
    /// entirely — which is how every existing dictionary-only behaviour is left
    /// exactly as it was.
    private let models: LanguageModelLibrary?

    /// Words the user reverted. Never offered again this session, so undoing a
    /// correction actually sticks instead of the same fix firing on the next
    /// keystroke.
    private var suppressed: Set<String> = []

    public var minimumLength: Int

    /// Whether to act on shape when no dictionary can help.
    public var correctsUnknownWords: Bool

    /// Whether the sentence a word landed in may speak for it, in either
    /// direction: for a correction, when a word of one or two letters is in the
    /// wrong alphabet for the line it sits in, and against one, when a word is
    /// perfectly at home in the language everything around it is written in.
    /// Off means the word is judged entirely alone, whatever surrounds it.
    public var usesContext: Bool

    /// How readily to do so.
    public var sensitivity: Sensitivity

    /// The order the user wants layouts considered in, best first, as layout
    /// identifiers. Only consulted when nothing about the words themselves can
    /// separate two readings.
    ///
    /// Empty means no order has been expressed, and that is the cautious default:
    /// two equally well evidenced readings then cancel each other out, exactly as
    /// they did before this existed.
    public var layoutPriority: [String]

    public init(
        lexicon: LexiconProvider,
        models: LanguageModelLibrary? = nil,
        minimumLength: Int = 3,
        correctsUnknownWords: Bool = true,
        usesContext: Bool = true,
        sensitivity: Sensitivity = .balanced,
        layoutPriority: [String] = []
    ) {
        self.lexicon = lexicon
        self.models = models
        self.minimumLength = minimumLength
        self.correctsUnknownWords = correctsUnknownWords
        self.usesContext = usesContext
        self.sensitivity = sensitivity
        self.layoutPriority = layoutPriority
    }

    // MARK: - Suppression

    public func suppress(_ text: String) {
        suppressed.insert(text.lowercased())
    }

    public func isSuppressed(_ text: String) -> Bool {
        suppressed.contains(text.lowercased())
    }

    public func clearSuppressions() {
        suppressed.removeAll()
    }

    // MARK: - Automatic path

    /// Words this short cannot be judged on their own, whatever the minimum
    /// length is set to. Two letters is the most that can be rescued by the
    /// sentence around them alone; beyond that the ordinary rules have enough to
    /// work with, and are far more careful.
    private static let contextRescueLimit = 2

    /// Evaluates a finished token. Returns `nil` far more often than not.
    public func evaluate(
        token: Token,
        activeLayout: KeyboardLayout,
        candidateLayouts: [KeyboardLayout],
        context: TypingContext = .none
    ) -> CorrectionProposal? {
        guard !token.isEmpty else { return nil }

        // Anything typed with command, control or option was an instruction to
        // the app, not prose.
        guard !token.keystrokes.contains(where: \.hasCommandChord) else { return nil }
        guard !isSuppressed(token.text) else { return nil }

        let straight = decide(
            proposals(
                for: token,
                activeLayout: activeLayout,
                candidateLayouts: candidateLayouts,
                context: context
            ),
            context: context
        )

        // A token wearing punctuation has a second reading: the word on its own,
        // with the punctuation left exactly as typed. `ghbdtn:` is either `приветЖ`
        // — since `:` on ABC is `Ж` on Russian — or `привет` followed by a colon.
        //
        // The straight reading goes first and keeps the answer whenever a
        // dictionary or a bracket in the middle of a word backs it up, because
        // then the punctuation genuinely was a letter: `ldjqye.` is `двойную`,
        // trailing `ю` and all. Short of that the punctuation is read as
        // punctuation, which is what it almost always is.
        guard let split = SplitToken(token) else { return straight }
        if let straight, straight.evidence.rank >= CorrectionEvidence.dictionary.rank {
            return straight
        }

        let kept = decide(
            proposals(
                for: split.core,
                activeLayout: activeLayout,
                candidateLayouts: candidateLayouts,
                context: context
            ),
            context: context
        )
        return kept.map(split.reattach) ?? straight
    }

    /// Every correction the watched layouts offer for one reading of a token.
    private func proposals(
        for token: Token,
        activeLayout: KeyboardLayout,
        candidateLayouts: [KeyboardLayout],
        context: TypingContext
    ) -> [CorrectionProposal] {
        // A word of one or two letters carries no evidence of its own — every
        // rule below needs more to go on than that. Only the sentence it landed
        // in can speak for it.
        if token.text.count <= Self.contextRescueLimit {
            return shortRescues(
                token: token,
                activeLayout: activeLayout,
                candidateLayouts: candidateLayouts,
                context: context
            )
        }

        guard TokenGuard.reasonToSkip(token.text, minimumLength: minimumLength) == nil else {
            return []
        }

        // A word that is real in a language the user actually types is not a
        // slip, whichever layout happened to be active when it was typed.
        //
        // Asking only the active layout's own language left a hole the exact
        // shape of the layouts macOS ships no dictionary for. Estonian is one,
        // and macOS remembers the layout per app — so it can be active without
        // anyone having chosen it that minute. With Estonian active nothing
        // could vouch for `her`, and `рук` is a perfectly good Russian word, so
        // `her` became `рук`.
        //
        // Still each layout's own primary language and no other, which is what
        // stops this silencing everything: ABC advertises 96, and among them sit
        // dictionaries permissive enough to accept any run of Latin letters at
        // all. The scripts keep to themselves for free — a dictionary that
        // cannot read the token says nothing, so a Latin word is only ever put
        // to Latin dictionaries and `ghbdtn` is still nobody's word.
        guard !isRealWord(token.text, in: [activeLayout] + candidateLayouts) else { return [] }

        // And a word that merely reads like one, in the language of the sentence
        // it landed in, is not a slip either.
        guard !contextDefends(token.text, source: activeLayout, context: context) else {
            return []
        }

        // Nor is a word that is one wrong key away from being one.
        guard !readsAsATypo(token, source: activeLayout) else { return [] }

        var accepted: [CorrectionProposal] = []

        for target in candidateLayouts where target.id != activeLayout.id {
            guard
                let candidate = LayoutMapper.translate(keystrokes: token.keystrokes, to: target),
                candidate != token.text,
                // A capital in the middle of a word is what a shifted punctuation
                // key looks like once it is read as a letter — `ghbdtn:` becomes
                // `приветЖ`, `Synara:` becomes `SynaraÖ`. Prose does not do that,
                // and `TokenGuard` already refuses to touch a token that does.
                !TokenGuard.isCamelCase(candidate),
                let proposal = judge(
                    original: token.text,
                    candidate: candidate,
                    keystrokes: token.keystrokes,
                    source: activeLayout,
                    target: target
                )
            else { continue }
            accepted.append(proposal)
        }

        return accepted
    }

    /// Whether any of these layouts' languages recognises the text as a word.
    private func isRealWord(_ text: String, in layouts: [KeyboardLayout]) -> Bool {
        Set(layouts.map(\.primaryLanguage)).contains {
            lexicon.verdict(for: text, language: $0) == .valid
        }
    }

    /// Whether the sentence around a word vouches for it staying as it is.
    ///
    /// Two things have to hold, and together they say something narrow: the user
    /// has been writing in the alphabet of the layout under their hands, and the
    /// word reads like an ordinary word of that language — by the very measure
    /// `PlausibilityRule` uses elsewhere to decide the opposite.
    ///
    /// This is what the dictionary rule was missing. It asks only whether the
    /// destination is a word, and for short strings the answer is too often yes:
    /// `NSSpellChecker` will call `шву` and `уду` Russian, while no English
    /// dictionary has heard of `ide` or `ele`. Nothing about those letters can
    /// settle it — but `IDE` became `ШВУ` in the middle of an English sentence,
    /// twice, and the sentence knew better both times.
    ///
    /// It costs nothing in the case Caret exists for, and the reason is worth
    /// setting down. Someone typing Russian on an English layout is writing into
    /// a window that fills up with Cyrillic — corrections go into it, not the
    /// text they replaced — while the layout under their hands says Latin. The
    /// two disagree, so this never engages. It engages only where layout and
    /// sentence already agree, which is precisely where nothing ever suggested a
    /// slip in the first place.
    private func contextDefends(
        _ original: String,
        source: KeyboardLayout,
        context: TypingContext
    ) -> Bool {
        guard usesContext, let models, let script = context.script else { return false }
        // Letters and nothing else. A word carrying punctuation is not "at home"
        // anywhere, and asking the question of it means asking about whatever is
        // left once the punctuation is stripped — which for `]un` is `un`, two
        // letters that read as unremarkable English and would have defended the
        // bracket that is the entire evidence for `õun`.
        guard original.allSatisfy(\.isLetter) else { return false }
        // The sentence and the layout have to be telling the same story, and the
        // word has to be part of it.
        guard Script.expected(forLanguage: source.primaryLanguage) == script else { return false }
        guard Script.dominant(in: original, minimumLetters: 1) == script else { return false }

        return PlausibilityRule(sensitivity: sensitivity).readsAsOrdinaryWord(
            original,
            model: models.model(for: source.primaryLanguage)
        )
    }

    /// Picks between the layouts that offered a correction, or refuses to.
    private func decide(
        _ accepted: [CorrectionProposal],
        context: TypingContext
    ) -> CorrectionProposal? {
        // Where they differ in how well evidenced they are, the better evidence
        // wins — a dictionary that recognises a word settles the matter against
        // a judgement about another word's shape.
        guard let best = accepted.map(\.evidence.rank).max() else { return nil }
        let strongest = accepted.filter { $0.evidence.rank == best }
        if strongest.count == 1 { return strongest[0] }

        // Layouts that disagree about which of them was meant, but agree on the
        // text, are not in conflict at all: there is only one correction on
        // offer. This happens whenever two layouts share an alphabet.
        if Set(strongest.map(\.corrected)).count == 1 { return strongest[0] }

        // Otherwise the sentence around the word can still break the tie: a
        // reading in the alphabet the user has been writing in all along is the
        // likelier one.
        if let script = context.script {
            let matching = strongest.filter {
                Script.dominant(in: $0.corrected, minimumLetters: 1) == script
            }
            if matching.count == 1 { return matching[0] }
        }

        // Nothing in the words themselves can separate them, so the user's own
        // order of preference does. This is the last word rather than the first
        // on purpose: which language someone mostly writes is a standing
        // preference, and it should never outrank evidence about the sentence
        // actually in front of them.
        if let preferred = highestPriority(among: strongest) { return preferred }

        // Two equally well supported readings, and nothing to choose between
        // them. Caret chooses neither.
        return nil
    }

    /// Whether the likelier story is one wrong key in the language the user was
    /// already writing.
    ///
    /// Stray punctuation is read everywhere else in this file as the fingerprint
    /// of a layout slip, and inside a short word it is one: prose does not put a
    /// bracket two characters into `]un`. Inside a long word it is just as likely
    /// to be a finger landing next door — `remarkab;e` for `remarkable`, `;`
    /// being one key from `l` — and Caret answered that with `remarkaböe`.
    /// Nothing about the punctuation alone tells the two apart.
    ///
    /// This is a claim about the language the text was typed in and no other, so
    /// it is made once and stands against every layout. Asking it per layout,
    /// and only where the user ranks the source language higher, was tried and
    /// is worse than useless: it silenced the reading it was aimed at and handed
    /// the word to the next layout along, turning `tab;e` into `ефижу` instead
    /// of `taböe`. A typo is a typo whoever else lays claim to it.
    ///
    /// The test is whether the key beside the one they hit spells a word
    /// outright: `;` sits one key right of `l`, so `he;;o` is `hello` typed by a
    /// pinky that slid, and `remarkab;e` is `remarkable`. Each stray character is
    /// put back as the keys either side of it, and if any combination is a real
    /// word in the language it was typed in, that is what it was.
    ///
    /// Only along the row, and `köök` is the reason. Allow the row above and `;`
    /// also reaches `o`, which turns `k;;k` into `kook` — an English word, and
    /// Estonian loses its own. A finger slides along the row it is already on.
    ///
    /// A dictionary and nothing weaker, because this overrules the punctuation
    /// outright. Judging the shape of what is left after deleting the stray was
    /// tried instead, and reads plausibly enough — `remarkabe` is unmistakably
    /// English — but measured against the whole Russian corpus it cost 247 real
    /// corrections to the dictionary's 24. Every Russian word beginning with `б`
    /// arrives with a leading comma, and `бегут`, `берут` and `бедные` were all
    /// being read as English words with a stray. A real word is a fact; a shape
    /// is a judgement, and at these odds only the fact is worth acting on.
    private func readsAsATypo(_ token: Token, source: KeyboardLayout) -> Bool {
        /// More than a handful of wrong keys is not a slip, and the combinations
        /// double with each one.
        let limit = 16
        var candidates: [String] = [""]
        var strays = 0

        for keystroke in token.keystrokes {
            let typed = keystroke.text
            let replacements: [String]
            if typed.allSatisfy(\.isLetter) {
                replacements = [typed]
            } else {
                strays += 1
                replacements = KeyGeometry.sameRowNeighbours(of: keystroke.keyCode)
                    .compactMap { source.character(for: $0, shift: keystroke.shift) }
                    .filter { $0.allSatisfy(\.isLetter) }
                // A key with no letter beside it cannot have been a slip of the
                // finger. `]` is one: its only neighbour is `[`.
                guard !replacements.isEmpty else { return false }
            }
            candidates = candidates.flatMap { prefix in replacements.map { prefix + $0 } }
            guard candidates.count <= limit else { return false }
        }

        guard strays > 0 else { return false }
        return candidates.contains {
            lexicon.verdict(for: $0, language: source.primaryLanguage) == .valid
        }
    }

    /// The proposal from the layout the user put first, if one of them stands
    /// alone at the top.
    ///
    /// A layout the user has never placed sits below every layout they have. Two
    /// unplaced layouts are still a tie, and still produce silence.
    private func highestPriority(among proposals: [CorrectionProposal]) -> CorrectionProposal? {
        guard !layoutPriority.isEmpty else { return nil }

        let positions = proposals.map {
            layoutPriority.firstIndex(of: $0.targetLayoutID) ?? layoutPriority.count
        }
        guard
            let best = positions.min(),
            positions.count(where: { $0 == best }) == 1,
            let index = positions.firstIndex(of: best)
        else { return nil }

        return proposals[index]
    }

    /// The lone `z` in a Russian sentence.
    ///
    /// Three things have to agree, and the order they are checked in is the order
    /// they are cheap in:
    ///
    ///   1. the sentence around the word is written in one alphabet, and not the
    ///      one the word is in;
    ///   2. the word is nothing but letters, and the conversion comes out wholly
    ///      in the sentence's alphabet;
    ///   3. the conversion is a far better shape than what was typed, by the
    ///      wide margin `evaluateShort` demands.
    ///
    /// The first is what makes the rest safe to attempt: `ok` and `it` are common
    /// enough inside English prose that judging them on shape alone would be
    /// reckless, and inside Russian prose they are rare enough to be worth the
    /// risk. Requiring only letters, and only lowercase ones, is what keeps
    /// initials, units and abbreviations out.
    ///
    /// No dictionary is consulted, because none has anything to say: measured on
    /// this machine, `NSSpellChecker` approves every one- and two-letter fragment
    /// it is shown, which is why `SystemSpellLexicon` refuses to pass its answer
    /// on at this length in the first place.
    private func shortRescues(
        token: Token,
        activeLayout: KeyboardLayout,
        candidateLayouts: [KeyboardLayout],
        context: TypingContext
    ) -> [CorrectionProposal] {
        guard usesContext, let models else { return [] }
        guard let script = context.script else { return [] }
        guard token.text.allSatisfy(\.isLetter) else { return [] }
        guard !token.text.contains(where: { Script($0) == script }) else { return [] }
        // `dB`, `mL`, `kB`, `J.` — units, abbreviations and initials are the one
        // thing a letter or two can be that is neither a word nor a slip, and a
        // capital gives all of them away. The lone letter this rule exists for is
        // a `z` in the middle of a line, lowercase like everything around it, so
        // the price is a capital `Я` at the start of a sentence going unfixed.
        guard !token.text.contains(where: \.isUppercase) else { return [] }

        let rule = PlausibilityRule(sensitivity: sensitivity)
        var accepted: [CorrectionProposal] = []

        for target in candidateLayouts where target.id != activeLayout.id {
            guard
                Script.expected(forLanguage: target.primaryLanguage) == script,
                let candidate = LayoutMapper.translate(keystrokes: token.keystrokes, to: target),
                candidate != token.text,
                candidate.allSatisfy({ Script($0) == script }),
                rule.acceptsShort(
                    original: token.text,
                    candidate: candidate,
                    sourceModel: models.model(for: activeLayout.primaryLanguage),
                    targetModel: models.model(for: target.primaryLanguage)
                )
            else { continue }

            accepted.append(
                CorrectionProposal(
                    original: token.text,
                    corrected: candidate,
                    targetLayoutID: target.id,
                    targetLayoutName: target.localizedName,
                    evidence: .context
                )
            )
        }

        return accepted
    }

    /// The heart of it. Both rules require evidence *for* the destination, and
    /// `proposals` has already established there is none for the original.
    private func judge(
        original: String,
        candidate: String,
        keystrokes: [Keystroke],
        source: KeyboardLayout,
        target: KeyboardLayout
    ) -> CorrectionProposal? {
        // The target layout is asked about its own language and no other, for
        // the same reason `proposals` asks each layout about only its own.
        let candidateVerdict = lexicon.verdict(for: candidate, language: target.primaryLanguage)

        func proposal(_ evidence: CorrectionEvidence) -> CorrectionProposal {
            CorrectionProposal(
                original: original,
                corrected: candidate,
                targetLayoutID: target.id,
                targetLayoutName: target.localizedName,
                evidence: evidence
            )
        }

        // Rule 1 — a dictionary vouches for the conversion.
        // Covers Russian↔ABC in both directions, and Estonian→ABC (`donät`
        // becomes `don't`, which English confirms).
        if candidateVerdict == .valid {
            return proposal(.dictionary)
        }

        // Rule 2 — nobody can vouch for the destination language, but the
        // conversion turns punctuation-littered text into a clean word.
        // Covers ABC→Estonian (`]un` becomes `õun`), where macOS ships no
        // Estonian dictionary to ask.
        //
        if candidateVerdict == .unknown,
           StructuralAnalyzer.isCleanerThan(candidate, original: original) {
            return proposal(.structural)
        }

        // Rule 3 — no dictionary will vouch for it, so judge the letters.
        //
        // This is the only rule that may fire over a dictionary's explicit
        // objection, and it has to be: `здарова` and `обводка` are both rejected
        // by the Russian dictionary, exactly as firmly as `ъыьъы` is. Slang,
        // regional spellings, clipped forms and plain typos all live in that
        // rejected pile, and no amount of asking a dictionary will get them out
        // of it. What separates them from noise is the shape of the letters.
        guard correctsUnknownWords, let models else { return nil }
        guard StructuralAnalyzer.isCleanWord(candidate) else { return nil }

        let rule = PlausibilityRule(sensitivity: sensitivity)
        if rule.accepts(
            original: original,
            candidate: candidate,
            keystrokes: keystrokes,
            sourceModel: models.model(for: source.primaryLanguage),
            targetModel: models.model(for: target.primaryLanguage)
        ) {
            return proposal(.plausibility)
        }

        return nil
    }

    // MARK: - Manual path

    /// Every conversion of `text` that produces something different, in the
    /// order the layouts were given.
    ///
    /// The manual trigger deliberately skips all the guards: the user asked, so
    /// the answer is whatever the layouts say. Cycling through the results is
    /// how they pick when more than one is plausible.
    public func manualCandidates(
        for text: String,
        from source: KeyboardLayout,
        layouts: [KeyboardLayout]
    ) -> [CorrectionProposal] {
        layouts
            .filter { $0.id != source.id }
            .compactMap { target in
                guard
                    let converted = LayoutMapper.translate(text: text, from: source, to: target),
                    converted != text
                else { return nil }
                return CorrectionProposal(
                    original: text,
                    corrected: converted,
                    targetLayoutID: target.id,
                    targetLayoutName: target.localizedName,
                    evidence: .manual
                )
            }
    }
}
