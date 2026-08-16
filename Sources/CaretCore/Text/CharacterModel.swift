import Foundation

/// How word-like a string is in one language, judged on shape alone.
///
/// This is the answer to the thing dictionaries cannot do. A dictionary knows
/// `здорово` and not `здарова`, so it rejects the slang spelling exactly as
/// firmly as it rejects `ъыьъы` — and a correction engine that trusts it stays
/// silent on half of what people actually type. But the two are not remotely
/// alike: `зд`, `да`, `ро`, `ва` are everyday Russian, while `ъы` and `ьъ` are
/// sequences the language essentially never produces. That difference is visible
/// in the letters themselves, without knowing the word.
///
/// So this counts letter triples. Trained on a list of real words it learns
/// which three-letter sequences a language is made of, and can then score a word
/// it has never seen. Slang scores well because slang is built out of ordinary
/// syllables. Typos score well because one wrong letter leaves the rest intact.
/// Text typed on the wrong keyboard scores terribly, because a layout slip
/// permutes letters into combinations the language has no use for.
///
/// Unseen sequences are the whole problem, so smoothing is not a detail: a raw
/// trigram count would call any unseen triple impossible and every score would
/// collapse to zero. Witten-Bell interpolation backs a sparse context off to the
/// pair, and a sparse pair off to the single letter, weighting each level by how
/// much evidence it actually has.
public struct CharacterModel: Sendable {

    /// Boundary marker. Padded either side of a word, so the model learns how
    /// words start and end as well as what happens inside them.
    private static let boundary = 0
    /// Every character the training data never contained. Its probability is
    /// whatever smoothing leaves it, which is close to nothing — correct, since
    /// a comma in the middle of a word is not something a language does.
    private static let unknown = 1
    private static let reservedSymbols = 2

    public let language: String

    /// Number of symbols, including the two reserved ones.
    private let size: Int
    private let index: [Character: Int]

    /// log P(c | a, b), laid out densely at `(a * size + b) * size + c`. Dense
    /// because it is small — a 36-symbol alphabet is 47k entries — and a flat
    /// array beats hashing on every keystroke.
    private let logProbabilities: [Float]

    /// Where real words of this language fall. Scores are per-character log
    /// probabilities, which are not comparable between languages: Russian
    /// spreads its mass over 33 letters and English over 26, so the same raw
    /// number means different things in each. Recording the distribution of
    /// genuine words makes the scale comparable — see `plausibility(of:)`.
    public let mean: Double
    public let deviation: Double

    /// Words the model was trained on, for the record.
    public let trainingWords: Int

    // MARK: - Training

    /// Builds a model from a word list. `nil` if there is not enough to learn
    /// from.
    public static func train(language: String, words: [String]) -> CharacterModel? {
        guard words.count >= 100 else { return nil }

        // The alphabet is whatever the data uses, so the model always matches
        // its corpus. Sorted, so training is deterministic.
        var alphabet: Set<Character> = []
        for word in words {
            alphabet.formUnion(word)
        }
        guard !alphabet.isEmpty else { return nil }

        let symbols = alphabet.sorted()
        let size = symbols.count + reservedSymbols
        var index: [Character: Int] = [:]
        for (offset, character) in symbols.enumerated() {
            index[character] = offset + reservedSymbols
        }

        // ---- counts

        var unigram = [Int](repeating: 0, count: size)
        var bigram = [Int](repeating: 0, count: size * size)
        var trigram = [Int](repeating: 0, count: size * size * size)

        var unigramTotal = 0
        for word in words {
            let sequence = [boundary, boundary] + word.map { index[$0] ?? unknown } + [boundary]
            for position in 2..<sequence.count {
                let a = sequence[position - 2], b = sequence[position - 1], c = sequence[position]
                unigram[c] += 1
                bigram[b * size + c] += 1
                trigram[(a * size + b) * size + c] += 1
                unigramTotal += 1
            }
        }

        // ---- Witten-Bell interpolation
        //
        // At each level the weight given to the observed distribution is
        // n / (n + t), where n is how often the context was seen and t how many
        // distinct characters followed it. A context seen often and followed by
        // few things is trusted; a context seen rarely, or followed by anything
        // at all, defers to the shorter one.

        // P(c): add-one over the alphabet, so no character is ever impossible.
        var singleton = [Double](repeating: 0, count: size)
        for c in 0..<size {
            singleton[c] = Double(unigram[c] + 1) / Double(unigramTotal + size)
        }

        // P(c | b)
        var pair = [Double](repeating: 0, count: size * size)
        for b in 0..<size {
            let row = b * size
            var total = 0
            var distinct = 0
            for c in 0..<size where bigram[row + c] > 0 {
                total += bigram[row + c]
                distinct += 1
            }
            let weight = Double(total + distinct)
            for c in 0..<size {
                guard distinct > 0 else { pair[row + c] = singleton[c]; continue }
                pair[row + c] =
                    (Double(bigram[row + c]) + Double(distinct) * singleton[c]) / weight
            }
        }

        // P(c | a, b)
        var logProbabilities = [Float](repeating: 0, count: size * size * size)
        for context in 0..<(size * size) {
            let row = context * size
            let backoffRow = (context % size) * size
            var total = 0
            var distinct = 0
            for c in 0..<size where trigram[row + c] > 0 {
                total += trigram[row + c]
                distinct += 1
            }
            let weight = Double(total + distinct)
            for c in 0..<size {
                let probability: Double
                if distinct == 0 {
                    probability = pair[backoffRow + c]
                } else {
                    probability =
                        (Double(trigram[row + c]) + Double(distinct) * pair[backoffRow + c]) / weight
                }
                logProbabilities[row + c] = Float(Foundation.log(max(probability, .leastNormalMagnitude)))
            }
        }

        // ---- calibration
        //
        // Measured on the training words themselves. That is mildly optimistic
        // for the language it was trained on, but the optimism is the same in
        // every language, and what the decision uses is the *difference* between
        // two languages' scores. Held-out words confirm the scale is right:
        // ordinary Russian absent from the corpus still lands near zero.

        let unscaled = CharacterModel(
            language: language,
            size: size,
            index: index,
            logProbabilities: logProbabilities,
            mean: 0,
            deviation: 1,
            trainingWords: words.count
        )

        var total = 0.0
        var totalSquares = 0.0
        for word in words {
            let score = unscaled.score(word)
            total += score
            totalSquares += score * score
        }
        let count = Double(words.count)
        let mean = total / count
        let variance = max(totalSquares / count - mean * mean, 1e-9)

        return CharacterModel(
            language: language,
            size: size,
            index: index,
            logProbabilities: logProbabilities,
            mean: mean,
            deviation: variance.squareRoot(),
            trainingWords: words.count
        )
    }

    private init(
        language: String,
        size: Int,
        index: [Character: Int],
        logProbabilities: [Float],
        mean: Double,
        deviation: Double,
        trainingWords: Int
    ) {
        self.language = language
        self.size = size
        self.index = index
        self.logProbabilities = logProbabilities
        self.mean = mean
        self.deviation = deviation
        self.trainingWords = trainingWords
    }

    // MARK: - Scoring

    /// Average log probability per character.
    ///
    /// Averaged rather than summed so that length does not decide the answer: a
    /// long word would otherwise always look less likely than a short one, and
    /// Caret has to compare words of different lengths against one threshold.
    public func score(_ word: String) -> Double {
        guard !word.isEmpty else { return mean }

        var a = Self.boundary
        var b = Self.boundary
        var total = 0.0
        var count = 0

        for character in word {
            let c = index[character] ?? Self.unknown
            total += Double(logProbabilities[(a * size + b) * size + c])
            count += 1
            a = b
            b = c
        }
        // The closing boundary. Scoring it is what lets the model object to a
        // word that stops somewhere the language never stops.
        total += Double(logProbabilities[(a * size + b) * size + Self.boundary])
        count += 1

        return total / Double(count)
    }

    /// How word-like `word` is, in standard deviations from an ordinary word of
    /// this language.
    ///
    /// Zero means "as unremarkable as any word in the dictionary". Negative
    /// means stranger than usual; far negative means the language does not build
    /// words this way. Because the unit is each language's own spread, a score
    /// from the Russian model and one from the English model can be compared,
    /// which is the entire point.
    public func plausibility(of word: String) -> Double {
        (score(word) - mean) / deviation
    }
}
