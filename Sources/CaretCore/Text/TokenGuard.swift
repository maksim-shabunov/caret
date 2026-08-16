import Foundation

/// Why Caret declined to touch a token.
///
/// Every one of these is a case where a "fix" would be worse than silence, so
/// they are checked before any dictionary work happens.
public enum SkipReason: Sendable, Equatable {
    case tooShort
    case noLetters
    case containsDigit
    case looksLikeAddress      // URL, email, @mention
    case looksLikePath
    case looksLikeIdentifier   // snake_case, camelCase, code
    case looksLikeContraction  // don't, novum's, 've
    case modifierChord
    case suppressed            // user reverted this exact word already
    case appExcluded
    case secureInput
}

/// The cheap, certain reasons to leave a token alone.
public enum TokenGuard {

    /// Characters that mark text as belonging to a machine rather than a
    /// sentence.
    ///
    /// Deliberately excludes `[ ] ; ' + -`: those are exactly what an
    /// Estonian/ABC layout slip produces, so treating them as "code" would
    /// blind Caret to the case it most needs to see.
    private static let machinePunctuation: Set<Character> = [
        "@", "/", "\\", "_", "#", "$", "%", "^", "&", "*",
        "<", ">", "=", "~", "|", "{", "}", "(", ")",
    ]

    public static func reasonToSkip(_ token: String, minimumLength: Int) -> SkipReason? {
        guard token.contains(where: \.isLetter) else { return .noLetters }

        // Length is measured on the word, not on the whole token. What matters
        // is how much of it Caret is actually being asked to judge, and a full
        // stop is no part of that: `it.` is two letters, two letters is below
        // every threshold there is, and no dictionary will vouch for a word that
        // short — `SystemSpellLexicon` says as much outright. Measured whole it
        // came to three, sailed past this guard, met a Russian dictionary that
        // was happy to call `шею` a word, and `it.` became `шею`.
        //
        // Only the punctuation prose ordinarily puts round a word is set aside,
        // which is what keeps the Estonian case alive: the leading bracket in
        // `]un` is the whole signal that a layout slip happened, and
        // `withoutEdgePunctuation` deliberately leaves it — along with `[` and
        // `'`, which are Estonian vowels on an ABC keyboard. Trimming every
        // non-letter would hide that evidence and take the token below the
        // threshold, which is exactly what this guard used to avoid by not
        // trimming at all.
        guard StructuralAnalyzer.withoutEdgePunctuation(token).count >= minimumLength else {
            return .tooShort
        }

        // A digit anywhere means a version, an identifier, a measurement or a
        // password fragment. None of those are words.
        if token.contains(where: \.isNumber) { return .containsDigit }

        let lowercased = token.lowercased()
        if lowercased.contains("://") || lowercased.hasPrefix("www.") {
            return .looksLikeAddress
        }
        if token.contains("@") { return .looksLikeAddress }
        if token.contains("/") || token.contains("\\") { return .looksLikePath }
        if token.contains("_") { return .looksLikeIdentifier }
        if isCamelCase(token) { return .looksLikeIdentifier }
        if token.contains(where: machinePunctuation.contains) { return .looksLikeIdentifier }

        // An apostrophe holding a possessive or a contraction together is prose,
        // and prose is not a slip however tidy the conversion looks.
        //
        // Every layout spends that key on something. `'` is `ä` on Estonian, so
        // `novum's` reads as `novumäs` — punctuation gone, clean word left,
        // exactly the fingerprint the structural rule looks for. It is `э` on
        // Russian, so `'ve` reads as `эму`, which a dictionary will happily call
        // a word. Both fired, and the dictionary hid how often by vouching for
        // `user's` and `section's` on its own: what got through were possessives
        // of the words English has never heard of, which is every name, brand
        // and package the user types.
        //
        // Estonian pays almost nothing for this. `ä` is the apostrophe key, so
        // `täna` arrives as `t'na` and `ära` as `'ra` — and `na` and `ra` are not
        // things English contracts to, so both still get through. What is lost
        // is a word ending in `ä` followed by a lone `s`, `t`, `d` or `m`.
        if StructuralAnalyzer.isContraction(token) { return .looksLikeContraction }

        return nil
    }

    /// A lowercase letter immediately followed by an uppercase one — `fooBar`.
    /// Ordinary prose never does this; code does it constantly.
    static func isCamelCase(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count > 1 else { return false }
        for index in 1..<characters.count
        where characters[index - 1].isLowercase && characters[index].isUppercase {
            return true
        }
        return false
    }
}
