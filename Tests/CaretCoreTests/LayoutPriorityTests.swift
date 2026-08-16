import Foundation
import Testing
@testable import CaretCore

/// The order the user puts their languages in, and the one thing it decides.
///
/// Caret's default answer to a genuinely ambiguous word is silence: `]un` is `õun`
/// in Estonian and `ъгт` in Russian, and if a dictionary vouched for both there is
/// nothing in the letters to choose between them. An order is the user telling
/// Caret what to do in that situation, and it is consulted last — after the
/// dictionaries, after the shape of the word, and after the alphabet of the
/// sentence around it. It breaks ties. It does not win arguments.
@Suite("Layout priority", .serialized)
@MainActor
struct LayoutPriorityTests {

    let abc: KeyboardLayout
    let russian: KeyboardLayout
    let estonian: KeyboardLayout
    let all: [KeyboardLayout]

    init() throws {
        abc = try #require(Fixtures.layout(LayoutID.abc))
        russian = try #require(Fixtures.layout(LayoutID.russian))
        estonian = try #require(Fixtures.layout(LayoutID.estonian))
        all = [abc, russian, estonian]
    }

    /// The same dead heat the engine suite uses for its silence test: teaching the
    /// lexicon that `ъгт` is a Russian word makes Russian and Estonian equally
    /// well evidenced readings of `]un`.
    func tiedEngine(priority: [String]) -> CorrectionEngine {
        CorrectionEngine(
            lexicon: MockLexicon(covered: ["ru"], words: ["ru": ["ъгт"]]),
            layoutPriority: priority
        )
    }

    func tiedProposal(priority: [String]) -> CorrectionProposal? {
        tiedEngine(priority: priority).evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        )
    }

    // MARK: - Breaking the tie

    @Test("The higher layout wins a contested word")
    func priorityDecides() throws {
        let estonianFirst = try #require(
            tiedProposal(priority: [LayoutID.estonian, LayoutID.russian, LayoutID.abc])
        )
        #expect(estonianFirst.corrected == "õun")

        // Reversed, and the answer reverses with it — proving the order decided it
        // rather than any preference of Caret's own.
        let russianFirst = try #require(
            tiedProposal(priority: [LayoutID.russian, LayoutID.estonian, LayoutID.abc])
        )
        #expect(russianFirst.corrected == "ъгт")
    }

    @Test("No order means no answer")
    func silentWithoutAnOrder() {
        #expect(tiedProposal(priority: []) == nil)
    }

    /// A layout the user has never placed — one installed since they last opened
    /// Settings — sits behind everything they have placed, so it cannot win a tie
    /// by accident.
    @Test("An unplaced layout loses to a placed one")
    func unplacedLayoutsComeLast() throws {
        let result = try #require(tiedProposal(priority: [LayoutID.russian]))
        #expect(result.corrected == "ъгт")
    }

    /// If neither contender is in the list there is still nothing to choose
    /// between them, and silence is still the answer.
    @Test("An order that mentions neither contender settles nothing")
    func irrelevantOrderStaysSilent() {
        #expect(tiedProposal(priority: [LayoutID.abc]) == nil)
    }

    /// The order is the last word, not the first. A layout at the bottom of the
    /// list still wins when it is the only one with any evidence behind it.
    @Test("Evidence outranks the order")
    func evidenceComesFirst() throws {
        let engine = CorrectionEngine(
            lexicon: SystemSpellLexicon(),
            layoutPriority: [LayoutID.abc, LayoutID.estonian, LayoutID.russian]
        )
        let result = try #require(engine.evaluate(
            token: Fixtures.token("ghbdtn", on: abc),
            activeLayout: abc,
            candidateLayouts: all
        ))
        #expect(result.corrected == "привет")
        #expect(result.targetLayoutID == LayoutID.russian)
    }

    /// So does the sentence the user is in the middle of writing. Context and
    /// priority disagree here on purpose: context wins, because it is evidence
    /// about this word and the order is only a standing preference.
    @Test("The surrounding alphabet outranks the order")
    func contextComesFirst() {
        let engine = tiedEngine(priority: [LayoutID.estonian, LayoutID.russian])
        #expect(engine.evaluate(
            token: Fixtures.token("]un", on: abc),
            activeLayout: abc,
            candidateLayouts: all,
            context: TypingContext(script: .cyrillic)
        )?.corrected == "ъгт")
    }

    // MARK: - Keeping the order

    func preferences() -> Preferences {
        // A suite of its own, wiped first, so the tests never see whatever the
        // real app last wrote.
        let name = "com.caret.tests.priority"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    @Test("Until the user arranges them, the system's order stands")
    func defaultsToTheSystemOrder() {
        #expect(preferences().ordered(all).map(\.id) == all.map(\.id))
    }

    @Test("Moving a layout writes the whole order back")
    func movingWritesTheOrder() {
        let prefs = preferences()
        prefs.movePriority(of: russian, by: -1, within: all)

        #expect(prefs.ordered(all).map(\.id) == [LayoutID.russian, LayoutID.abc, LayoutID.estonian])
        // Every layout, not just the moved one — the order has to stop depending
        // on whatever the system reports next time it is asked.
        #expect(prefs.layoutPriority.count == all.count)
    }

    @Test("Moving off either end does nothing")
    func movingPastTheEndsIsIgnored() {
        let prefs = preferences()
        prefs.movePriority(of: abc, by: -1, within: all)
        #expect(prefs.layoutPriority.isEmpty)

        prefs.movePriority(of: estonian, by: 1, within: all)
        #expect(prefs.layoutPriority.isEmpty)
    }

    @Test("A layout installed since the user last looked keeps its place at the back")
    func newLayoutsSortLast() {
        let prefs = preferences()
        prefs.layoutPriority = [LayoutID.estonian, LayoutID.russian]

        #expect(prefs.ordered(all).map(\.id) == [
            LayoutID.estonian, LayoutID.russian, LayoutID.abc,
        ])
    }

    @Test("The order survives being written and read back")
    func orderPersists() {
        let name = "com.caret.tests.priority.persistence"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let first = Preferences(defaults: defaults)
        first.movePriority(of: estonian, by: -1, within: all)
        let written = first.ordered(all).map(\.id)

        #expect(Preferences(defaults: defaults).ordered(all).map(\.id) == written)
        defaults.removePersistentDomain(forName: name)
    }
}
