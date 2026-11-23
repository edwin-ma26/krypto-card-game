import Foundation

struct Card: Identifiable, Equatable {
    let id: UUID
    var value: Fraction
    var colorIndex: Int

    init(value: Fraction, colorIndex: Int) {
        self.id = UUID()
        self.value = value
        self.colorIndex = colorIndex
    }

    /// A card with a caller-chosen id, for displays that rebuild the same
    /// hand repeatedly (the solve replay) and need stable identity.
    init(id: UUID, value: Fraction, colorIndex: Int) {
        self.id = id
        self.value = value
        self.colorIndex = colorIndex
    }
}

struct SolutionStep {
    let a: Fraction
    let op: Operation
    let b: Fraction
    let result: Fraction
}

/// A shared hand/target dealt to both players in a live race, so `onChange`
/// can detect a fresh deal (e.g. a rematch) even while other state is unchanged.
///
/// `round` is a monotonic counter bumped on every fresh deal. Without it, a
/// "New Game" that happened to deal the same hand+target as the current one
/// would be `==` the existing puzzle, so the change listener wouldn't fire and
/// the board would keep the old game. Keying on `round` makes each deal
/// distinct regardless of the cards.
struct SharedPuzzle: Equatable {
    let hand: [Int]
    let target: Int
    let round: Int
}

enum Krypto {
    /// Standard Krypto deck: 1–6 ×3, 7–10 ×4, 11–17 ×2, 18–25 ×1 (56 cards).
    static var deck: [Int] {
        var d: [Int] = []
        for v in 1...6 { d.append(contentsOf: Array(repeating: v, count: 3)) }
        for v in 7...10 { d.append(contentsOf: Array(repeating: v, count: 4)) }
        for v in 11...17 { d.append(contentsOf: Array(repeating: v, count: 2)) }
        for v in 18...25 { d.append(v) }
        return d
    }

    /// Deals 5 hand cards plus a target, redealing until the hand is solvable.
    static func deal() -> (hand: [Int], target: Int) {
        while true {
            let shuffled = deck.shuffled()
            let hand = Array(shuffled.prefix(5))
            let target = shuffled[5]
            if solve(hand.map { Fraction($0) }, target: Fraction(target)) != nil {
                return (hand, target)
            }
        }
    }

    /// Number of distinct solution paths, stopping early at `cap`. Mirrors
    /// `countSolutions` in functions/src/krypto.ts so the device-side
    /// estimate below agrees with the server's for the daily puzzle.
    static func countSolutions(_ values: [Fraction], target: Fraction, cap: Int) -> Int {
        if values.count == 1 { return values[0] == target ? 1 : 0 }
        var count = 0
        for i in 0..<values.count where count < cap {
            for j in 0..<values.count where i != j && count < cap {
                var rest = values
                rest.remove(at: max(i, j))
                rest.remove(at: min(i, j))
                for op in Operation.allCases {
                    guard let result = op.apply(values[i], values[j]) else { continue }
                    count += countSolutions(rest + [result], target: target, cap: cap - count)
                    if count >= cap { break }
                }
            }
        }
        return count
    }

    /// Difficulty-based solve-time estimate, 30–180s: a hand with only a few
    /// solution paths plays much harder to *find* than one with dozens. Same
    /// curve as `estimateSolveSeconds` in functions/src/krypto.ts; used by
    /// Single Player's rating as the puzzle's median before enough real
    /// solves exist (see `SoloRating.PuzzleModel`).
    static func estimateSolveSeconds(hand: [Int], target: Int) -> Int {
        let minSeconds = 30.0, maxSeconds = 180.0, halfLife = 6.0, searchCap = 30
        let solutions = countSolutions(hand.map { Fraction($0) }, target: Fraction(target), cap: searchCap)
        return Int((minSeconds + (maxSeconds - minSeconds) / (1 + Double(solutions) / halfLife)).rounded())
    }

    /// Depth-first search over all pairings and operations; returns the steps of one solution.
    static func solve(_ values: [Fraction], target: Fraction) -> [SolutionStep]? {
        if values.count == 1 {
            return values[0] == target ? [] : nil
        }
        for i in 0..<values.count {
            for j in 0..<values.count where i != j {
                var rest = values
                let b = rest.remove(at: max(i, j))
                let a = rest.remove(at: min(i, j))
                let (x, y) = i < j ? (a, b) : (b, a)
                for op in Operation.allCases {
                    // + and × are commutative; skip the mirrored pair once.
                    if (op == .add || op == .multiply) && i > j { continue }
                    guard let result = op.apply(x, y) else { continue }
                    if let steps = solve(rest + [result], target: target) {
                        return [SolutionStep(a: x, op: op, b: y, result: result)] + steps
                    }
                }
            }
        }
        return nil
    }
}
