import Foundation
import Testing
@testable import CaretCore

/// The layouts these tests are written against. Identifiers rather than
/// localised names, so the tests read the same on any system language.
enum LayoutID {
    static let abc = "com.apple.keylayout.ABC"
    static let russian = "com.apple.keylayout.Russian"
    static let estonian = "com.apple.keylayout.Estonian"
}

@MainActor
enum Fixtures {
    /// The layouts these tests are written against, read from a snapshot rather
    /// than from the machine running them.
    ///
    /// They used to come from `KeyboardLayoutReader`, which was honest but made
    /// the suite depend on which input sources this particular Mac happens to
    /// have *enabled* — so it passed here and would have failed anywhere else,
    /// continuous integration included, where only ABC is switched on. The
    /// snapshot is the same data the reader would have produced, taken from a
    /// real system by `Tools/DumpLayouts.swift` and committed. Re-run that if a
    /// layout ever needs adding.
    ///
    /// `KeyboardLayoutReader` is still exercised, in `LayoutMapperTests`, but
    /// against whatever the machine actually has rather than against three
    /// layouts it is required to have.
    static let installed: [KeyboardLayout] = {
        guard
            let url = Bundle.module.url(forResource: "Layouts", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard
                let id = entry["id"] as? String,
                let name = entry["localizedName"] as? String,
                let languages = entry["languages"] as? [String],
                let plain = entry["plain"] as? [String: String],
                let shifted = entry["shifted"] as? [String: String]
            else { return nil }

            func keyed(_ map: [String: String]) -> [UInt16: String] {
                Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                    UInt16(key).map { ($0, value) }
                })
            }

            return KeyboardLayout(
                id: id,
                localizedName: name,
                languages: languages,
                plain: keyed(plain),
                shifted: keyed(shifted)
            )
        }
    }()

    static func layout(_ id: String) -> KeyboardLayout? {
        installed.first { $0.id == id }
    }

    /// Builds keystrokes as though each character were typed on `layout`.
    ///
    /// This is the honest way to simulate typing: it goes through the layout's
    /// own reverse map, so the keycodes are the ones the hardware would really
    /// have sent.
    static func type(_ text: String, on layout: KeyboardLayout) -> [Keystroke] {
        text.enumerated().compactMap { index, character in
            guard let key = layout.reverse[character] else { return nil }
            return Keystroke(
                keyCode: key.keyCode,
                shift: key.shift,
                text: String(character),
                timestamp: Double(index) * 0.08
            )
        }
    }

    static func token(_ text: String, on layout: KeyboardLayout, trailing: String = " ") -> Token {
        let keystrokes = type(text, on: layout)
        return Token(keystrokes: keystrokes, text: text, trailing: trailing)
    }

    // MARK: - Character models

    /// The real bundled models, trained once for the whole test run.
    ///
    /// These tests deliberately use the committed corpora rather than toy word
    /// lists: the thresholds in `Sensitivity` were chosen by measuring against
    /// this exact data, so a test built on anything else would prove nothing
    /// about them. The `Task` is stored before it is awaited, so tests running
    /// in parallel share one training pass instead of racing to duplicate it.
    private static var modelTask: Task<LanguageModelLibrary, Never>?

    static func models() async -> LanguageModelLibrary {
        if let modelTask { return await modelTask.value }
        let task = Task { @MainActor in
            let library = LanguageModelLibrary()
            await library.warm(languages: ["ru", "en"])
            return library
        }
        modelTask = task
        return await task.value
    }

    /// A lexicon that has heard of neither word — which is the situation the
    /// shape-based rule exists for, and the situation `здарова`, `обводка` and
    /// every typo are genuinely in.
    static func blankLexicon() -> MockLexicon {
        MockLexicon(covered: ["ru", "en"], words: [:])
    }
}

/// A lexicon with hand-fed answers, for testing the decision rules in isolation
/// from whatever dictionaries the machine happens to have.
@MainActor
final class MockLexicon: LexiconProvider {
    var covered: Set<String>
    var words: [String: Set<String>]

    init(covered: Set<String>, words: [String: Set<String>]) {
        self.covered = covered
        self.words = words
    }

    func coverage(for language: String) -> LexiconCoverage {
        covered.contains(language) ? .available : .unavailable
    }

    func verdict(for token: String, language: String) -> WordVerdict {
        guard covered.contains(language) else { return .unknown }
        return words[language, default: []].contains(token.lowercased()) ? .valid : .invalid
    }
}
