import Foundation

/// Where word lists come from. A seam, so tests can train tiny models from
/// literals instead of the real corpora.
public protocol WordListSource: Sendable {
    /// Language codes there is a list for, exactly as named.
    var availableLanguages: [String] { get }
    func words(forLanguage language: String) -> [String]?
}

/// Exists only to be asked which binary it came from.
private final class BundleLocator {}

/// The lists harvested from the system lexicon and committed into the package.
///
/// Deliberately does not use `Bundle.module`. The accessor SwiftPM generates for
/// it calls `fatalError` when the bundle is missing, and looks for it at the root
/// of the main bundle — which for an assembled `.app` means unsealed content
/// beside `Contents`, breaking the code signature that the Accessibility grant
/// depends on. Both are wrong here: the lists have to sit in `Contents/Resources`
/// like any other resource, and a missing list has to be survivable. Without one,
/// there is simply no model for that language and Caret falls back to the
/// dictionary rules.
public struct BundledWordLists: WordListSource {
    private static let directory = "LanguageModels"

    public init() {}

    /// Everywhere the lists might legitimately be.
    ///
    /// Found relative to this module's own binary rather than to `Bundle.main`,
    /// because under `swift test` the main bundle is Xcode's `xctest` tool and
    /// knows nothing about this package — the reason SwiftPM's own accessor falls
    /// back to an absolute path baked in at build time. Locating by class gives
    /// the `.app` in production and the `.xctest` bundle under test, and the
    /// resource bundle sits beside each of them.
    private static var searchPaths: [URL] {
        let home = Bundle(for: BundleLocator.self)
        var roots: [URL] = []

        // Copied into Resources by build.sh.
        if let resources = home.resourceURL { roots.append(resources) }
        // SwiftPM's resource bundle, beside whatever linked this module.
        for neighbour in [home.bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL] {
            roots.append(neighbour.appendingPathComponent("Caret_CaretCore.bundle"))
        }
        if let resources = Bundle.main.resourceURL { roots.append(resources) }

        return roots.map { $0.appendingPathComponent(directory) }
    }

    public var availableLanguages: [String] {
        for path in Self.searchPaths {
            let contents = try? FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil
            )
            guard let contents, !contents.isEmpty else { continue }
            return contents
                .filter { $0.pathExtension == "txt" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()
        }
        return []
    }

    public func words(forLanguage language: String) -> [String]? {
        for path in Self.searchPaths {
            let url = path.appendingPathComponent(language).appendingPathExtension("txt")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        }
        return nil
    }
}

/// Holds one `CharacterModel` per language, trained on demand.
///
/// Training is a few hundred milliseconds of pure arithmetic over fifty thousand
/// words, which is far too long to do while someone is typing. So it happens off
/// the main thread at launch, and until it finishes `model(for:)` simply answers
/// `nil` — the dictionary and structural rules carry on working, and the
/// shape-based rule joins in once it is ready.
@MainActor
public final class LanguageModelLibrary {

    private let source: WordListSource
    private var models: [String: CharacterModel] = [:]
    private var resolved: [String: String?] = [:]
    private var started: Set<String> = []

    public init(source: WordListSource = BundledWordLists()) {
        self.source = source
    }

    /// The model for a language, or `nil` if there is no list for it or it has
    /// not finished training.
    ///
    /// Estonian is the honest `nil` here: macOS ships no Estonian lexicon of any
    /// kind, so there is nothing to harvest and nothing to train. Estonian
    /// slips are caught by their punctuation instead, which is what they look
    /// like — `õun` typed on ABC comes out as `]un`.
    public func model(for language: String) -> CharacterModel? {
        guard let key = resolve(language) else { return nil }
        return models[key]
    }

    public func hasModel(for language: String) -> Bool {
        model(for: language) != nil
    }

    /// Trains whatever is missing, off the main thread. Safe to call repeatedly;
    /// each language is trained once.
    public func warm(languages: [String]) async {
        for language in languages {
            guard let key = resolve(language), !started.contains(key) else { continue }
            started.insert(key)

            let source = self.source
            let model = await Task.detached(priority: .utility) { () -> CharacterModel? in
                guard let words = source.words(forLanguage: key) else { return nil }
                return CharacterModel.train(language: key, words: words)
            }.value

            if let model { models[key] = model }
        }
    }

    /// Maps a layout's language onto a list that exists. A layout may report
    /// `en_GB` where the list is named `en`.
    private func resolve(_ language: String) -> String? {
        if let cached = resolved[language] { return cached }

        let available = source.availableLanguages
        let result: String?
        if available.contains(language) {
            result = language
        } else if let base = language.split(whereSeparator: { $0 == "_" || $0 == "-" }).first,
                  available.contains(String(base)) {
            result = String(base)
        } else {
            result = available.first { language.hasPrefix($0 + "_") || language.hasPrefix($0 + "-") }
        }

        resolved[language] = result
        return result
    }
}
