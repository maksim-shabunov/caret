import Foundation
import Testing
@testable import CaretCore

@Suite("Layout mapping")
@MainActor
struct LayoutMapperTests {

    @Test("The layouts these tests are written against")
    func expectedLayoutsPresent() throws {
        let ids = Set(Fixtures.installed.map(\.id))
        #expect(ids.contains(LayoutID.abc))
        #expect(ids.contains(LayoutID.russian))
        #expect(ids.contains(LayoutID.estonian))
    }

    @Test("Every layout in the snapshot exposes usable key data")
    func layoutsHaveKeyData() throws {
        for layout in Fixtures.installed {
            #expect(!layout.plain.isEmpty, "\(layout.localizedName) produced no key map")
            #expect(!layout.reverse.isEmpty, "\(layout.localizedName) produced no reverse map")
        }
    }

    /// The one test that still asks the system, so that reading real layouts
    /// stays covered without requiring any particular one to be switched on. A
    /// Mac always has at least one keyboard, and whatever it is must produce a
    /// usable map — that is the whole contract `KeyboardLayoutReader` owes.
    @Test("Reading the layouts this machine actually has")
    func readsInstalledLayouts() throws {
        let live = KeyboardLayoutReader.enabledLayouts()
        #expect(!live.isEmpty, "the system reported no keyboard layouts at all")
        for layout in live {
            #expect(!layout.plain.isEmpty, "\(layout.id) produced no key map")
            #expect(!layout.primaryLanguage.isEmpty)
        }
    }

    // MARK: - Russian ↔ ABC, where every letter key differs

    @Test("Latin typed on ABC becomes the Russian it was meant to be")
    func russianFromKeystrokes() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        let keystrokes = Fixtures.type("ghbdtn", on: abc)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: russian) == "привет")
    }

    @Test("Case survives the trip")
    func russianPreservesCase() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        let keystrokes = Fixtures.type("Ghbdtn", on: abc)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: russian) == "Привет")
    }

    @Test("And back the other way")
    func englishFromRussianKeystrokes() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        let keystrokes = Fixtures.type("руддщ", on: russian)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: abc) == "hello")
    }

    // MARK: - Estonian ↔ ABC, where only punctuation differs

    @Test("A bracket on ABC is really an Estonian vowel")
    func estonianFromKeystrokes() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let estonian = try #require(Fixtures.layout(LayoutID.estonian))

        let keystrokes = Fixtures.type("]un", on: abc)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: estonian) == "õun")
    }

    @Test("Semicolons on ABC are Estonian o-umlauts")
    func estonianDoubleVowel() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let estonian = try #require(Fixtures.layout(LayoutID.estonian))

        let keystrokes = Fixtures.type("k;;k", on: abc)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: estonian) == "köök")
    }

    @Test("An apostrophe typed on Estonian comes out as an a-umlaut")
    func englishContractionFromEstonian() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let estonian = try #require(Fixtures.layout(LayoutID.estonian))

        let keystrokes = Fixtures.type("donät", on: estonian)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: abc) == "don't")
    }

    @Test("Letters are identical between Estonian and ABC")
    func estonianLettersUnchanged() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let estonian = try #require(Fixtures.layout(LayoutID.estonian))

        let keystrokes = Fixtures.type("tere", on: abc)
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: estonian) == "tere")
    }

    // MARK: - Character route, used by the manual trigger on a selection

    @Test("Selected text converts without ever seeing the keystrokes")
    func characterRoute() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        #expect(LayoutMapper.translate(text: "ghbdtn", from: abc, to: russian) == "привет")
        #expect(LayoutMapper.translate(text: "привет", from: russian, to: abc) == "ghbdtn")
    }

    @Test("Whitespace passes through, so phrases convert intact")
    func characterRoutePhrase() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        let converted = LayoutMapper.translate(text: "ghbdtn rfr ltkf", from: abc, to: russian)
        #expect(converted == "привет как дела")
    }

    @Test("Round tripping returns the original")
    func roundTrip() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        let there = try #require(LayoutMapper.translate(text: "hello world", from: abc, to: russian))
        let back = LayoutMapper.translate(text: there, from: russian, to: abc)
        #expect(back == "hello world")
    }

    @Test("Text with nothing mappable is refused rather than mangled")
    func unmappableTextReturnsNil() throws {
        let abc = try #require(Fixtures.layout(LayoutID.abc))
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        #expect(LayoutMapper.translate(text: "🙂🙃", from: abc, to: russian) == nil)
    }

    @Test("An unmapped key aborts the whole conversion")
    func unmappedKeycodeReturnsNil() throws {
        let russian = try #require(Fixtures.layout(LayoutID.russian))

        // No layout has a key here, so the whole token must be refused rather
        // than silently converted with a hole in it.
        let keystrokes = [Keystroke(keyCode: 999, shift: false, text: "?", timestamp: 0)]
        #expect(LayoutMapper.translate(keystrokes: keystrokes, to: russian) == nil)
    }
}
