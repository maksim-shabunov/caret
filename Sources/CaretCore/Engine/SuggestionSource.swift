import Foundation

/// Something that can look at what was just typed and propose a replacement.
///
/// `CorrectionEngine` is the only implementation today. The protocol exists so
/// that a second kind of suggestion can be added later without the event tap,
/// the typing buffer or the text replacer knowing anything about it — they all
/// speak in tokens and proposals already.
@MainActor
public protocol SuggestionSource: AnyObject {
    func evaluate(
        token: Token,
        activeLayout: KeyboardLayout,
        candidateLayouts: [KeyboardLayout],
        context: TypingContext
    ) -> CorrectionProposal?
}

extension CorrectionEngine: SuggestionSource {}
