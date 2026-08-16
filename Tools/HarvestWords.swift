// Harvests a word list for each language Caret needs to recognise.
//
// Run from build-models.sh, not at runtime. The output is committed, so builds
// and tests are reproducible and the app never depends on what a particular
// machine happens to have installed.
//
// Where the words come from: `NSSpellChecker.completions(forPartialWordRange:)`
// is the one public API on macOS that will *enumerate* a language's lexicon
// rather than merely check a word against it. Asked for "зд" it answers
// "здравствуйте, здоровы, здании, …". It caps each answer at twenty, so the
// harvest walks a prefix tree: any prefix that comes back full is asked again
// one letter deeper, because a capped answer means there was more to say.
//
// The result is Apple's keyboard-suggestion lexicon — conversational rather
// than literary, which is exactly the register this is meant to model.

import AppKit
import Foundation

// MARK: - What to harvest

struct Target {
    let language: String
    /// Letters the prefix walk is allowed to use.
    let alphabet: [Character]
    /// Characters permitted inside a harvested word, beyond the alphabet.
    let joiners: Set<Character>
}

let targets = [
    Target(
        language: "ru",
        alphabet: Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        joiners: ["-"]
    ),
    Target(
        language: "en",
        alphabet: Array("abcdefghijklmnopqrstuvwxyz"),
        joiners: ["'", "-"]
    ),
]

/// The most completions macOS will return for one prefix. Measured, not
/// documented: a prefix that returns exactly this many has been truncated.
let responseCap = 20

/// How deep the prefix walk may go, and how many questions it may ask in total.
///
/// Both matter. Nearly every short prefix comes back full, so an unbounded walk
/// branches by the whole alphabet at every level and never finishes — 33⁶ is a
/// billion prefixes. Depth three is the useful stopping point: character
/// statistics converge long before the lexicon is exhausted, so the words found
/// past it are almost all trigrams already seen thousands of times.
let maxDepth = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 3
let callBudget = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 40_000

// MARK: - Harvest

let checker = NSSpellChecker.shared
let outputDirectory = URL(fileURLWithPath: "Sources/CaretCore/LanguageModels")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for target in targets {
    guard checker.availableLanguages.contains(where: { $0 == target.language || $0.hasPrefix(target.language + "_") })
    else {
        FileHandle.standardError.write(
            Data("no dictionary for \(target.language) — skipped\n".utf8)
        )
        continue
    }

    let permitted = Set(target.alphabet).union(target.joiners)
    var words: Set<String> = []
    var queue: [String] = target.alphabet.map(String.init)
    var calls = 0
    let started = Date()

    while let prefix = queue.popLast(), calls < callBudget {
        calls += 1
        if calls % 2000 == 0 {
            FileHandle.standardError.write(Data(
                "  \(target.language): \(calls) prefixes, \(words.count) words, \(queue.count) queued\n".utf8
            ))
        }
        let completions = checker.completions(
            forPartialWordRange: NSRange(location: 0, length: prefix.utf16.count),
            in: prefix,
            language: target.language,
            inSpellDocumentWithTag: 0
        ) ?? []

        for completion in completions {
            // Suggestions arrive capitalised where the lexicon holds them that
            // way ("Как"). Case is not part of what is being modelled.
            let word = completion.lowercased()
            guard word.count >= 2, word.allSatisfy(permitted.contains) else { continue }
            words.insert(word)
        }

        // A full response was truncated: there is more under this prefix.
        if completions.count >= responseCap, prefix.count < maxDepth {
            for letter in target.alphabet {
                queue.append(prefix + String(letter))
            }
        }
    }

    // Sorted so the file is stable across runs and diffs cleanly.
    let sorted = words.sorted()
    let url = outputDirectory.appendingPathComponent("\(target.language).txt")
    try (sorted.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

    let elapsed = Date().timeIntervalSince(started)
    let size = (try? Data(contentsOf: url).count) ?? 0
    print(String(
        format: "%@: %d words from %d prefixes in %.1fs (%d KB)",
        target.language, sorted.count, calls, elapsed, size / 1024
    ))
}
