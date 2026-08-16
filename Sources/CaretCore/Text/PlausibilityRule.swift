import Foundation

/// How much Caret is willing to act on shape alone.
///
/// The dictionary rules need no setting: a dictionary either recognises a word or
/// it does not, and Caret has been right or wrong about it before the user sees
/// anything. Shape is different. It is a judgement about degree, and where the
/// line belongs genuinely depends on what someone types all day. Somebody writing
/// Russian slang wants `ваще` fixed; somebody pasting identifiers and stock
/// tickers into a terminal would rather Caret kept its hands still.
public enum Sensitivity: String, CaseIterable, Codable, Sendable {
    /// Only words that look thoroughly ordinary in the other language.
    case cautious
    /// Slang and single-letter typos, which is what most people mean by "fix it".
    case balanced
    /// Anything the other language could plausibly have produced.
    case eager

    public var title: String {
        switch self {
        case .cautious: "Cautious"
        case .balanced: "Balanced"
        case .eager: "Eager"
        }
    }

    public var explanation: String {
        switch self {
        case .cautious:
            "Corrects words a dictionary knows, plus text that reads as completely ordinary in another language."
        case .balanced:
            "Also corrects slang and typos — anything shaped like a real word, spelled correctly or not."
        case .eager:
            "Corrects whenever another layout gives a more word-like reading. Catches the most, and occasionally acts on something it should have left alone."
        }
    }

    var thresholds: PlausibilityRule.Thresholds {
        switch self {
        case .cautious:
            .init(
                candidateFloor: -3.0, originalCeiling: -5.0,
                margin: 3.0, shortMargin: 6.5, minimumLength: 5
            )
        case .balanced:
            .init(
                candidateFloor: -5.5, originalCeiling: -4.0,
                margin: 2.0, shortMargin: 5.5, minimumLength: 4
            )
        case .eager:
            .init(
                candidateFloor: -7.0, originalCeiling: -3.0,
                margin: 1.5, shortMargin: 4.0, minimumLength: 4
            )
        }
    }
}

/// Decides, on shape alone, whether text belongs to another layout.
///
/// The rule is a pair of statements that have to hold together, and deliberately
/// not a single score:
///
///   1. the conversion looks like a word in the language it would belong to, and
///   2. what was actually typed does not look like one where it was typed.
///
/// Requiring both is what keeps it honest. An earlier version scored the
/// *difference* between the two readings, which sounds equivalent and is not: a
/// difference can be made large by the typed text being terrible, regardless of
/// whether the conversion is any good. `hjkl` read as Russian gives `ролд`, and
/// because `hjkl` is such hopeless English the gap between them is wider than
/// for any real correction Caret makes. Judging the two sides separately means
/// the conversion has to earn its place on its own.
///
/// A small margin is still required on top, so that a mediocre reading can never
/// beat a slightly-worse one on a technicality.
public struct PlausibilityRule: Sendable {

    struct Thresholds: Sendable {
        /// How word-like the conversion must be, in standard deviations from an
        /// ordinary word of the target language.
        let candidateFloor: Double
        /// How unlike a word the typed text must be, in the language it was
        /// typed in.
        let originalCeiling: Double
        /// The least the conversion must beat the original by.
        let margin: Double
        /// The same, for a word of one or two letters, where nothing but the
        /// comparison is left to go on. Several times the ordinary margin,
        /// because it is being asked to carry the whole decision.
        let shortMargin: Double
        /// Below this, a token is too short for its shape to mean anything.
        let minimumLength: Int
    }

    /// Why a shape-based correction was declined. Useful in tests, where "it
    /// returned nil" is not enough to know the rule is working for the right
    /// reason.
    public enum Refusal: Error, Sendable, Equatable {
        case tooShort
        case keyboardRun
        case noModel(language: String)
        case candidateNotWordLike(score: Double)
        case originalLooksFine(score: Double)
        case tooClose(margin: Double)
    }

    public struct Verdict: Sendable, Equatable {
        public let candidateScore: Double
        public let originalScore: Double
        public var margin: Double { candidateScore - originalScore }
    }

    private let thresholds: Thresholds

    public init(sensitivity: Sensitivity) {
        thresholds = sensitivity.thresholds
    }

    /// The full answer, including why not.
    public func evaluate(
        original: String,
        candidate: String,
        keystrokes: [Keystroke],
        sourceModel: CharacterModel?,
        targetModel: CharacterModel?
    ) -> Result<Verdict, Refusal> {
        // Punctuation at the edges is ordinary text and no part of the word. It
        // is trimmed for scoring but *not* for the length test, which the token
        // guard has already applied to the raw token.
        let candidateWord = StructuralAnalyzer.trimmed(candidate.lowercased())
        let originalWord = StructuralAnalyzer.trimmed(original.lowercased())

        guard candidateWord.count >= thresholds.minimumLength else {
            return .failure(.tooShort)
        }
        // Fingers walking across the board, not words.
        guard !KeyGeometry.isRun(keystrokes: keystrokes) else {
            return .failure(.keyboardRun)
        }
        // Both languages have to be measurable, or the comparison is one-sided.
        // Estonian lands here, and lands here honestly: macOS ships nothing to
        // learn Estonian from, so Caret does not guess about it.
        guard let targetModel else { return .failure(.noModel(language: "target")) }
        guard let sourceModel else { return .failure(.noModel(language: "source")) }

        let candidateScore = targetModel.plausibility(of: candidateWord)
        guard candidateScore >= thresholds.candidateFloor else {
            return .failure(.candidateNotWordLike(score: candidateScore))
        }

        let originalScore = sourceModel.plausibility(of: originalWord)
        guard originalScore <= thresholds.originalCeiling else {
            return .failure(.originalLooksFine(score: originalScore))
        }

        let margin = candidateScore - originalScore
        guard margin >= thresholds.margin else {
            return .failure(.tooClose(margin: margin))
        }

        return .success(Verdict(candidateScore: candidateScore, originalScore: originalScore))
    }

    /// The same comparison for a word of one or two letters, where the absolute
    /// scores have nothing left to say.
    ///
    /// A corpus of ordinary words cannot tell you how plausible a single letter
    /// is. Measured against the shipped Russian list, `я` scores −5.9 and `о`
    /// −8.2 — worse than text this rule throws out at full length, because a
    /// one-letter word is a rare shape whatever the letter. Every absolute
    /// threshold is therefore useless here, and only the comparison between the
    /// two readings has any resolution left: `z` is −12.9 as English against
    /// `я` at −5.9, and that seven-deviation gap is the whole of the evidence.
    ///
    /// Judging the difference is precisely what the main rule refuses to do, for
    /// the good reason given above, so this is a genuine weakening and is treated
    /// as one. The margin demanded is around three times the ordinary one, and the
    /// caller may only ask at all when the surrounding sentence has already said
    /// which alphabet is being written in. The geometry check is skipped because
    /// at this length it has nothing to say: a run takes four keys.
    ///
    /// It is not airtight, and the gaps are of one kind. Short English words that
    /// convert to shapely Cyrillic — `if` to `ша`, `tv` to `ем` — clear the margin
    /// and would be corrected inside a Russian sentence. Both are refused the
    /// moment the sentence around them is English, which is where they are
    /// overwhelmingly typed.
    public func evaluateShort(
        original: String,
        candidate: String,
        sourceModel: CharacterModel?,
        targetModel: CharacterModel?
    ) -> Result<Verdict, Refusal> {
        guard let targetModel else { return .failure(.noModel(language: "target")) }
        guard let sourceModel else { return .failure(.noModel(language: "source")) }

        let candidateScore = targetModel.plausibility(of: candidate.lowercased())
        let originalScore = sourceModel.plausibility(of: original.lowercased())

        let margin = candidateScore - originalScore
        guard margin >= thresholds.shortMargin else {
            return .failure(.tooClose(margin: margin))
        }

        return .success(Verdict(candidateScore: candidateScore, originalScore: originalScore))
    }

    /// Whether text reads like an ordinary word of the language it was typed in.
    ///
    /// The same threshold as `originalCeiling`, asked from the other side. There
    /// the question is whether the typed text is strange enough in its own
    /// language to be a slip; here it is whether it is ordinary enough not to be.
    /// One rule, so the sensitivity setting keeps meaning one thing.
    public func readsAsOrdinaryWord(_ text: String, model: CharacterModel?) -> Bool {
        guard let model else { return false }
        let word = StructuralAnalyzer.trimmed(text.lowercased())
        guard !word.isEmpty else { return false }
        return model.plausibility(of: word) > thresholds.originalCeiling
    }

    /// `evaluateShort`, when only the answer matters.
    public func acceptsShort(
        original: String,
        candidate: String,
        sourceModel: CharacterModel?,
        targetModel: CharacterModel?
    ) -> Bool {
        if case .success = evaluateShort(
            original: original,
            candidate: candidate,
            sourceModel: sourceModel,
            targetModel: targetModel
        ) { return true }
        return false
    }

    /// The same question, when only the answer matters.
    public func accepts(
        original: String,
        candidate: String,
        keystrokes: [Keystroke],
        sourceModel: CharacterModel?,
        targetModel: CharacterModel?
    ) -> Bool {
        if case .success = evaluate(
            original: original,
            candidate: candidate,
            keystrokes: keystrokes,
            sourceModel: sourceModel,
            targetModel: targetModel
        ) { return true }
        return false
    }
}
