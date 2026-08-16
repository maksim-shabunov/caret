import Foundation

/// Where each key physically sits on the board.
///
/// Keycodes describe positions, not letters, so this grid is the same whatever
/// layout is active — which is exactly what makes it useful here. It answers one
/// question: did this text trace a path across the keyboard rather than spell
/// something?
///
/// That matters because the shape-based correction rule has one blind spot it
/// cannot reason its way out of. `hjkl` is four vim keystrokes; read through a
/// Russian layout it becomes `ролд`, which has the shape of a perfectly ordinary
/// Russian syllable. `zxcvbn` becomes `ячсмит`. Judged on letter statistics
/// alone these are indistinguishable from genuine mistyped words, because
/// statistically that is what they are. The thing that gives them away is not in
/// the letters at all — it is that the fingers walked in a straight line.
public enum KeyGeometry {

    /// The physical rows, left to right, as keycodes. Grave sits at the left of
    /// the number row where the hardware puts it, and the ISO key at the left of
    /// the bottom row on European boards.
    private static let rows: [[UInt16]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [10, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]

    private static let positions: [UInt16: (row: Int, column: Int)] = {
        var positions: [UInt16: (row: Int, column: Int)] = [:]
        for (row, keys) in rows.enumerated() {
            for (column, key) in keys.enumerated() {
                positions[key] = (row, column)
            }
        }
        return positions
    }()

    /// Two keys a finger could slide between: touching, including diagonally.
    ///
    /// Rows are staggered rather than aligned, so this is an approximation of
    /// physical distance. It does not need to be better than that — the question
    /// is whether a whole token moved one key at a time, and a run of four or
    /// more accidental near-neighbours is not something typing produces.
    public static func areAdjacent(_ first: UInt16, _ second: UInt16) -> Bool {
        guard let a = positions[first], let b = positions[second] else { return false }
        return abs(a.row - b.row) <= 1 && abs(a.column - b.column) <= 1
    }

    /// Whether every key in the sequence touches the one before it.
    ///
    /// `hjkl`, `qwerty`, `asdfgh`, `zxcvbn` and `wasd` all answer true; every
    /// word in the test corpora answers false. Three keys are too few to be
    /// sure — plenty of real words contain two adjacent letters — so this asks
    /// for four.
    public static func isRun(_ keyCodes: [UInt16]) -> Bool {
        guard keyCodes.count >= 4 else { return false }
        for index in 1..<keyCodes.count {
            guard areAdjacent(keyCodes[index - 1], keyCodes[index]) else { return false }
        }
        return true
    }

    public static func isRun(keystrokes: [Keystroke]) -> Bool {
        isRun(keystrokes.map(\.keyCode))
    }

    /// The keys immediately left and right of this one, on its own row.
    ///
    /// Deliberately not the diagonals that `areAdjacent` accepts. The question
    /// here is a different one — which key did the user *mean* — and the answer
    /// to that is overwhelmingly the one their finger slid off, along the row
    /// their hand was already on. Admitting the row above turns `k;;k` into
    /// `kook`, which is an English word, and Estonian would lose `köök` to it.
    public static func sameRowNeighbours(of keyCode: UInt16) -> [UInt16] {
        guard let position = positions[keyCode] else { return [] }
        let row = rows[position.row]
        return [position.column - 1, position.column + 1]
            .filter(row.indices.contains)
            .map { row[$0] }
    }
}
