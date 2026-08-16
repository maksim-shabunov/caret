import Foundation

/// The writing systems Caret can tell apart. Enough to spot a token that mixes
/// scripts, which almost always means a layout slip rather than real text.
public enum Script: Sendable, Hashable {
    case latin
    case cyrillic
    case other

    public init(_ character: Character) {
        guard let scalar = character.unicodeScalars.first, character.isLetter else {
            self = .other
            return
        }
        switch scalar.value {
        // Basic Latin, Latin-1 Supplement, Latin Extended-A/B.
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x00FF, 0x0100...0x024F:
            self = .latin
        // Cyrillic and Cyrillic Supplement.
        case 0x0400...0x04FF, 0x0500...0x052F:
            self = .cyrillic
        default:
            self = .other
        }
    }
}

public extension Script {
    /// The script a language is written in, where Caret is sure.
    ///
    /// Returns `nil` for anything it has no opinion about — the point is to
    /// catch a dictionary being asked about text it cannot read, not to
    /// classify every language on earth.
    static func expected(forLanguage language: String) -> Script? {
        let code = language.prefix(while: { $0 != "_" && $0 != "-" }).lowercased()
        if cyrillicLanguages.contains(code) { return .cyrillic }
        if latinLanguages.contains(code) { return .latin }
        return nil
    }

    /// The script a passage is written in, when one clearly dominates.
    ///
    /// Deliberately strict, because this is used to decide what the *next* word
    /// was meant to be. A sentence with a stray foreign word in it still answers
    /// with the language it is written in; a sentence genuinely half in each
    /// answers `nil`, and Caret keeps its hands still.
    static func dominant(
        in text: some Sequence<Character>,
        minimumLetters: Int = 5,
        share: Double = 0.8
    ) -> Script? {
        var counts: [Script: Int] = [:]
        var letters = 0
        for character in text where character.isLetter {
            counts[Script(character), default: 0] += 1
            letters += 1
        }
        guard letters >= minimumLetters else { return nil }
        guard let (script, count) = counts.max(by: { $0.value < $1.value }), script != .other else {
            return nil
        }
        return Double(count) / Double(letters) >= share ? script : nil
    }

    /// Languages macOS ships dictionaries for, split by script. Only these are
    /// gated; an unrecognised language is left to the spell checker.
    private static let cyrillicLanguages: Set<String> = ["ru", "uk", "bg", "mk", "sr", "be"]
    private static let latinLanguages: Set<String> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "sv", "da", "nb", "nn", "no",
        "fi", "pl", "cs", "sk", "sl", "hr", "hu", "ro", "tr", "ga", "id", "ms",
        "et", "lv", "lt", "is", "ca", "eu", "gl", "af", "sq", "vi",
    ]
}

public extension StringProtocol {
    /// Distinct scripts among the letters in this string.
    var scripts: Set<Script> {
        Set(filter(\.isLetter).map(Script.init))
    }
}
