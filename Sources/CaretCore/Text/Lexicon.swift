import AppKit
import Foundation

/// How confident we are that a piece of text is a real word.
public enum WordVerdict: Sendable, Equatable {
    /// A dictionary recognised it.
    case valid
    /// A dictionary was consulted and rejected it.
    case invalid
    /// No dictionary was available for this language. Says nothing either way.
    case unknown
}

/// Whether a language can be checked at all.
public enum LexiconCoverage: Sendable, Equatable {
    case available
    case unavailable
}

/// A source of "is this a word?" answers.
///
/// The seam exists so a bundled word list can be added later — Estonian being
/// the obvious candidate, since macOS ships no Estonian dictionary — without
/// the correction engine changing at all.
@MainActor
public protocol LexiconProvider: AnyObject {
    func coverage(for language: String) -> LexiconCoverage
    func verdict(for token: String, language: String) -> WordVerdict
}

/// Uses the dictionaries macOS already ships, via `NSSpellChecker`.
///
/// On this machine that covers Russian and English but not Estonian, which is
/// exactly why `CorrectionEngine` has to work from structural evidence too.
///
/// `NSSpellChecker` is a *proofreader*, not a word validator: it scans text for
/// misspellings and reports the first one it finds. Asked a question it cannot
/// answer it says nothing, which reads as approval. Measured on this machine it
/// approves every one- and two-letter fragment (`un`, `kk`, `t`), anything with
/// punctuation it can skip over (`]un`, `k;;k`), and any text in a script its
/// dictionary does not cover (`руддщ` is impeccable English). Each of those
/// would have silenced a correction Caret should make, so the checks below turn
/// all three into `.unknown` — an honest "no opinion" — before it is asked.
@MainActor
public final class SystemSpellLexicon: LexiconProvider {

    /// Below this length the system checker approves almost anything, so its
    /// answer carries no information either way.
    private static let shortestTrustworthyToken = 3

    /// Characters that belong inside a word. Anything else means the checker
    /// would be judging a fragment rather than the token it was handed.
    private static let wordCharacters: Set<Character> = ["'", "’", "-", "‑"]

    private let checker: NSSpellChecker
    private let available: Set<String>
    private var resolved: [String: String?] = [:]
    private var cache: [Cacheable: WordVerdict] = [:]

    private struct Cacheable: Hashable {
        let token: String
        let language: String
    }

    public init(checker: NSSpellChecker = .shared) {
        self.checker = checker
        self.available = Set(checker.availableLanguages)
    }

    public func coverage(for language: String) -> LexiconCoverage {
        resolve(language) == nil ? .unavailable : .available
    }

    public func verdict(for token: String, language: String) -> WordVerdict {
        guard let resolvedLanguage = resolve(language) else { return .unknown }

        // Always ask about the lowercased form. `NSSpellChecker` accepts many
        // capitalised unknowns as proper nouns, which would silently hide the
        // very case Caret most needs to catch: a mistyped first word of a
        // sentence. Precision is unaffected, because a correction still
        // requires the *candidate* to come back valid.
        //
        // Edge punctuation goes too: a full stop or a closing bracket beside a
        // word is ordinary text, and the word is what the question is about.
        let normalised = StructuralAnalyzer.trimmed(token.lowercased())
        guard normalised.count >= Self.shortestTrustworthyToken else { return .unknown }
        guard normalised.allSatisfy({ $0.isLetter || Self.wordCharacters.contains($0) }) else {
            return .unknown
        }
        // A dictionary cannot read a script it does not cover, and says so by
        // finding no fault at all.
        if let script = Script.expected(forLanguage: resolvedLanguage),
           !normalised.scripts.subtracting([.other]).isSubset(of: [script]) {
            return .unknown
        }

        let key = Cacheable(token: normalised, language: resolvedLanguage)
        if let cached = cache[key] { return cached }

        let range = checker.checkSpelling(
            of: normalised,
            startingAt: 0,
            language: resolvedLanguage,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let verdict: WordVerdict
        if range.location != NSNotFound {
            verdict = .invalid
        } else {
            verdict = trusts(normalised, language: resolvedLanguage) ? .valid : .unknown
        }

        // Bounded so a long session cannot grow this without limit.
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = verdict
        return verdict
    }

    /// Whether a clean bill of health from the checker actually means anything.
    ///
    /// The checker splits a token at apostrophes and hyphens and waves through
    /// any piece shorter than three letters, so `t'na` and `k-la` come back as
    /// impeccable English while `zz'qq` does not. That is the difference between
    /// leaving the Estonian word `täna` alone and mangling it into `t'na`, so a
    /// pass earned that way is downgraded to "no opinion".
    ///
    /// English contractions are the one case where a one- or two-letter piece is
    /// a real word ending rather than a fragment too small to argue with.
    private func trusts(_ token: String, language: String) -> Bool {
        let fragments = token.split(whereSeparator: Self.wordCharacters.contains)
        guard fragments.contains(where: { $0.count < Self.shortestTrustworthyToken }) else {
            return true
        }
        guard
            language.hasPrefix("en"),
            fragments.count == 2,
            token.contains(where: { $0 == "'" || $0 == "’" }),
            let stem = fragments.first, !stem.isEmpty,
            let ending = fragments.last,
            StructuralAnalyzer.contractionEndings.contains(String(ending))
        else { return false }
        return true
    }

    /// Maps a layout's language code onto a dictionary the system actually has.
    /// `en` may only be present as `en_GB`, so fall back to a prefix match.
    private func resolve(_ language: String) -> String? {
        if let cached = resolved[language] { return cached }

        let result: String?
        if available.contains(language) {
            result = language
        } else if let regional = available.first(where: { $0.hasPrefix(language + "_") }) {
            result = regional
        } else {
            result = nil
        }

        resolved[language] = result
        return result
    }
}

/// Signals that need no dictionary at all.
///
/// This is what carries the Estonian case. Estonian and ABC differ only in
/// punctuation keys, so a layout slip leaves a very distinctive fingerprint:
/// `õun` typed on ABC becomes `]un`, and a bracket in the middle of a word is
/// not something any language does.
public enum StructuralAnalyzer {

    /// Characters that legitimately appear inside a word.
    private static let wordInterior: Set<Character> = ["'", "’", "-", "‑", "."]

    private static let apostrophes: Set<Character> = ["'", "’"]

    /// The only word endings short enough to be untrustworthy on their own and
    /// yet genuinely English.
    static let contractionEndings: Set<String> = ["t", "s", "d", "m", "re", "ve", "ll"]

    /// Punctuation prose ordinarily puts *before* a word.
    ///
    /// Deliberately short, and two absences are the interesting part. `[` is left
    /// out because Estonian `ü` is `[` on an ABC keyboard, so `üks` arrives as
    /// `[ks`; `'` is left out because Estonian `ä` is `'`, so `ära` arrives as
    /// `'ra` — and an apostrophe is a word character here in any case. A leading
    /// bracket or straight quote in genuine prose is rare enough to lose.
    private static let ordinaryOpeners: Set<Character> = ["\"", "“", "«", "(", "¿", "¡"]

    /// … and after it. Longer, because far more punctuation ends a word than
    /// begins one.
    private static let ordinaryClosers: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", "\"", "”", "'", "’", "»", ")", "]", "}",
    ]

    /// Whether one keystroke's worth of text is punctuation prose puts before a
    /// word.
    static func isOrdinaryOpener(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return ordinaryOpeners.contains(character)
    }

    /// Whether one keystroke's worth of text is punctuation prose puts after one.
    static func isOrdinaryCloser(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return ordinaryClosers.contains(character)
    }

    /// The token with the punctuation prose ordinarily puts round a word taken
    /// off both ends. `"his:"` becomes `his`; `]un` is left alone.
    static func withoutEdgePunctuation(_ token: String) -> String {
        var characters = Array(token)
        while let first = characters.first, ordinaryOpeners.contains(first) {
            characters.removeFirst()
        }
        while let last = characters.last, ordinaryClosers.contains(last) {
            characters.removeLast()
        }
        return String(characters)
    }

    /// A token that reads like an ordinary word: letters, optionally joined by
    /// an apostrophe or hyphen.
    public static func isCleanWord(_ token: String) -> Bool {
        let core = trimmed(token)
        guard core.count >= 2 else { return false }
        guard core.contains(where: \.isLetter) else { return false }
        return core.allSatisfy { $0.isLetter || wordInterior.contains($0) }
    }

    /// How many characters are not letters.
    ///
    /// This is the measure that carries the Estonian case. A layout slip
    /// sprinkles punctuation through text that should be pure letters, and it
    /// does so wherever the mistyped key happened to fall — leading (`]un`),
    /// interior (`k;;k`) or trailing. Counting is position-independent, so it
    /// catches all three where a "symbol between two letters" test would miss
    /// the first.
    public static func nonLetterCount(_ token: String) -> Int {
        token.count { !$0.isLetter }
    }

    /// An apostrophe doing the ordinary job English gives it: `don't`,
    /// `novum's`, `they're`, and the bare `'ve` left behind when a contraction
    /// is split across a line.
    ///
    /// Exactly one apostrophe, nothing but letters to the left of it — or
    /// nothing at all — and one of the seven endings English contracts to on the
    /// right. Everything looser is left to the structural rule, which is what
    /// Estonian needs: `ä` is the apostrophe key on an ABC keyboard, so `täna`
    /// arrives as `t'na` and `ära` as `'ra`, and neither `na` nor `ra` is
    /// something English contracts to. The one Estonian word this costs would
    /// have to end in `ä` followed by a single `s`, `t`, `d` or `m`, and be
    /// unknown to every dictionary besides.
    public static func isContraction(_ token: String) -> Bool {
        let parts = token.lowercased().split(
            omittingEmptySubsequences: false,
            whereSeparator: apostrophes.contains
        )
        guard parts.count == 2, parts[0].allSatisfy(\.isLetter) else { return false }
        return contractionEndings.contains(String(parts[1]))
    }

    /// Latin and Cyrillic in the same token. Real words never do this.
    public static func mixesScripts(_ token: String) -> Bool {
        let found = token.scripts.subtracting([.other])
        return found.count > 1
    }

    /// `candidate` reads more like a word than `original` does.
    ///
    /// True when the candidate is a clean run of letters and the original
    /// carried punctuation the candidate does not — the fingerprint of typing
    /// on the wrong layout.
    ///
    /// Punctuation at the *edges* of the original does not count towards that,
    /// and the one misfire this rule has ever produced is why. Every punctuation
    /// key on an ABC keyboard is a letter on some other layout: `:` is `Ö` on
    /// Estonian, so `his:` converts to `hisÖ` — punctuation gone, clean word
    /// left, precisely the fingerprint being looked for. But a colon after a word
    /// is a colon, and no amount of looking at the conversion can tell it from a
    /// mistyped letter. So the evidence has to come from punctuation where prose
    /// would never have put it: inside the word (`k;;k` → `köök`), or against an
    /// edge prose does not use (`]un` → `õun`).
    ///
    /// An apostrophe would have been the second misfire, since `'` is `ä` on an
    /// Estonian keyboard and `novum's` therefore converts to `novumäs` — but a
    /// contraction never reaches here at all. `TokenGuard` turns it away as
    /// prose, which is both cheaper and true of every layout rather than only
    /// this rule.
    public static func isCleanerThan(_ candidate: String, original: String) -> Bool {
        guard isCleanWord(candidate) else { return false }
        if mixesScripts(original) { return true }
        return nonLetterCount(candidate) < nonLetterCount(withoutEdgePunctuation(original))
    }

    /// Drops leading and trailing punctuation, which is ordinary in real text.
    static func trimmed(_ token: String) -> String {
        var characters = Array(token)
        while let first = characters.first, !first.isLetter, !first.isNumber {
            characters.removeFirst()
        }
        while let last = characters.last, !last.isLetter, !last.isNumber {
            characters.removeLast()
        }
        return String(characters)
    }
}
