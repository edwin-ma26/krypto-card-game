import Foundation

/// Exact rational arithmetic so division never loses precision mid-game.
struct Fraction: Equatable, Hashable, CustomStringConvertible {
    var num: Int
    var den: Int

    init(_ num: Int, _ den: Int = 1) {
        precondition(den != 0)
        let sign = den < 0 ? -1 : 1
        let g = Fraction.gcd(abs(num), abs(den))
        self.num = sign * num / max(g, 1)
        self.den = sign * den / max(g, 1)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    var isWhole: Bool { den == 1 }

    var description: String {
        isWhole ? "\(num)" : "\(num)/\(den)"
    }

    static func + (l: Fraction, r: Fraction) -> Fraction {
        Fraction(l.num * r.den + r.num * l.den, l.den * r.den)
    }
    static func - (l: Fraction, r: Fraction) -> Fraction {
        Fraction(l.num * r.den - r.num * l.den, l.den * r.den)
    }
    static func * (l: Fraction, r: Fraction) -> Fraction {
        Fraction(l.num * r.num, l.den * r.den)
    }
    /// Returns nil when dividing by zero.
    static func divide(_ l: Fraction, by r: Fraction) -> Fraction? {
        r.num == 0 ? nil : Fraction(l.num * r.den, l.den * r.num)
    }
}

enum Operation: String, CaseIterable, Identifiable {
    case add = "+", subtract = "−", multiply = "×", divide = "÷"
    var id: String { rawValue }

    func apply(_ a: Fraction, _ b: Fraction) -> Fraction? {
        switch self {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide: return Fraction.divide(a, by: b)
        }
    }
}
