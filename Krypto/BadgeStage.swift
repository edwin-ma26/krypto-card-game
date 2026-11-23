import SwiftUI

/// How far the Founding Pup has mutated. Stage is the number of people you've
/// referred, capped at `.cosmic` — the dog gets stranger every time somebody
/// joins on your code, and there's deliberately nowhere to go after the last
/// one so it can't quietly stop being a reward.
enum BadgeStage: Int, CaseIterable, Comparable {
    case pup = 0
    case thirdEye = 1
    case manyEyed = 2
    case cosmic = 3

    static func < (lhs: BadgeStage, rhs: BadgeStage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Clamps a raw referral count into a stage.
    init(referrals: Int) {
        self = BadgeStage(rawValue: min(max(referrals, 0), BadgeStage.cosmic.rawValue)) ?? .pup
    }

    var title: String {
        switch self {
        case .pup: return "The Founding Pup"
        case .thirdEye: return "The Third-Eyed Pup"
        case .manyEyed: return "The Beholder Pup"
        case .cosmic: return "The Cosmic Pup"
        }
    }

    var blurb: String {
        switch self {
        case .pup:
            return "Awarded to players who shared Krypto before Competition Mode opened. It can't be earned any more \u{2014} whoever's wearing this was here first."
        case .thirdEye:
            return "One friend joined on their code, and the pup opened an eye it did not previously have. Nobody has explained this."
        case .manyEyed:
            return "Two referrals in. The eyes have multiplied and something is growing out of its head. It seems happy about it."
        case .cosmic:
            return "Three or more referrals. The pup has ascended, achieved a halo, and is no longer strictly a dog. This is the final form. Probably."
        }
    }

    /// Shown under your own badge as the nudge toward the next mutation.
    var nextHint: String? {
        switch self {
        case .pup: return "Refer 1 friend to see what happens to him."
        case .thirdEye: return "Refer 1 more. It gets worse."
        case .manyEyed: return "One more referral triggers the final form."
        case .cosmic: return nil
        }
    }

    // MARK: - Palette

    /// Ring colors, so an evolved badge is distinguishable at inline sizes
    /// where the dog itself is too small to read.
    var ringColors: [Color] {
        switch self {
        case .pup:
            return [Color(red: 0.95, green: 0.78, blue: 0.35), Color(red: 0.82, green: 0.58, blue: 0.20)]
        case .thirdEye:
            return [Color(red: 0.55, green: 0.82, blue: 0.72), Color(red: 0.24, green: 0.58, blue: 0.55)]
        case .manyEyed:
            return [Color(red: 0.76, green: 0.55, blue: 0.90), Color(red: 0.46, green: 0.28, blue: 0.70)]
        case .cosmic:
            return [Color(red: 0.42, green: 0.36, blue: 0.92), Color(red: 0.90, green: 0.35, blue: 0.72)]
        }
    }

    var fur: Color {
        switch self {
        case .pup, .thirdEye: return Color(red: 0.78, green: 0.58, blue: 0.38)
        case .manyEyed: return Color(red: 0.70, green: 0.55, blue: 0.62)
        case .cosmic: return Color(red: 0.44, green: 0.40, blue: 0.70)
        }
    }

    var furDark: Color {
        switch self {
        case .pup, .thirdEye: return Color(red: 0.62, green: 0.43, blue: 0.26)
        case .manyEyed: return Color(red: 0.52, green: 0.38, blue: 0.48)
        case .cosmic: return Color(red: 0.30, green: 0.26, blue: 0.54)
        }
    }

    var hasThirdEye: Bool { self >= .thirdEye }
    var hasCheekEyes: Bool { self >= .manyEyed }
    var hasAntennae: Bool { self >= .manyEyed }
    var isCosmic: Bool { self == .cosmic }
}
