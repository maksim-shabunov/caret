import Foundation

/// A token with the punctuation around it set aside.
///
/// There are two ways to read `ghbdtn:` — the keys of `привет` followed by a
/// colon, or the keys of `приветЖ`, since `:` on an ABC keyboard is `Ж` on a
/// Russian one. Every punctuation key is a letter somewhere, so every token that
/// ends in one has both readings available, and they cannot both be right.
///
/// This is the second of them: the word alone, with whatever was around it left
/// exactly as it was typed. `CorrectionEngine` tries the straight reading first
/// and only falls back to this one, because sometimes the punctuation really is
/// the letter — `ldjqye.` is `двойную`, trailing `ю` and all.
struct SplitToken {
    /// Punctuation taken off the front, as typed.
    let prefix: String
    /// The word in the middle, with the keystrokes that made it.
    let core: Token
    /// Punctuation taken off the end, as typed.
    let suffix: String

    /// `nil` when there was no ordinary punctuation to set aside, or nothing but
    /// punctuation to set it aside from.
    init?(_ token: Token) {
        var keystrokes = token.keystrokes
        var prefix = ""
        var suffix = ""

        // Walked over the keystrokes rather than the text, so the two can never
        // drift apart: the core's keys have to be exactly the keys that produced
        // the core's characters, or replaying them through another layout would
        // reconstruct the wrong word.
        while let first = keystrokes.first, StructuralAnalyzer.isOrdinaryOpener(first.text) {
            prefix += first.text
            keystrokes.removeFirst()
        }
        while let last = keystrokes.last, StructuralAnalyzer.isOrdinaryCloser(last.text) {
            suffix = last.text + suffix
            keystrokes.removeLast()
        }

        guard !prefix.isEmpty || !suffix.isEmpty else { return nil }
        let text = keystrokes.map(\.text).joined()
        guard text.contains(where: \.isLetter) else { return nil }

        self.prefix = prefix
        self.suffix = suffix
        core = Token(keystrokes: keystrokes, text: text, trailing: token.trailing)
    }

    /// Puts the punctuation back round a correction of the core.
    ///
    /// Both halves of the proposal are rebuilt, `original` included: what it says
    /// has to be exactly what is on screen, because that is what gets deleted.
    func reattach(_ proposal: CorrectionProposal) -> CorrectionProposal {
        var reattached = proposal
        reattached.original = prefix + proposal.original + suffix
        reattached.corrected = prefix + proposal.corrected + suffix
        return reattached
    }
}
