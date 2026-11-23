import SwiftUI

/// Named tiers laid over a rating. Solo and Ranked each keep their own
/// number underneath (one is beat-the-clock against the field, the other is
/// head-to-head Elo), but share these names so a badge reads the same
/// anywhere in the app.
///
/// Each tier spans the range up to the next tier's floor and is split into
/// `divisionsPerTier` divisions, numbered IV (lowest) down to I. The top tier
/// has no divisions — there is nothing above it to split towards.
///
/// For Solo the floors have a direct meaning: a rating is the performance
/// rating of the share of the field a player consistently beats, so Gold's
/// floor (1200) is "better than half the field", Platinum's "better than
/// three quarters", Diamond's "better than nine in ten", Master's "better
/// than 97 in 100" and Grandmaster "top 1%".
///
/// Divisions follow the rating exactly. Tiers have hysteresis: a player is
/// promoted the moment they reach a floor, but only demoted once they fall
/// `demotionMargin` or more below it. With the margin one more than
/// `SoloRating.maxSwing`, a single bad puzzle right after a promotion can
/// never undo it. The held tier is persisted (`soloTier` / `rankedTier`)
/// so the displayed badge survives the dip.
struct RatingTiers: Equatable {
    struct Tier: Equatable {
        let name: String
        let floor: Int
    }

    var tiers: [Tier]
    var divisionsPerTier: Int
    var demotionMargin: Int
    /// Rated solo puzzles a player must complete before a tier is shown at
    /// all; until then they are "Unranked". Matches the free-puzzle count
    /// before sign-in, so the badge first appears as a reward for signing in.
    var unrankedUntil: Int
    /// Rated ranked matches a player must finish before a ranked tier is
    /// shown — the placement run. Until then the badge reads "Unranked" and
    /// no held tier is written, so the first badge is the band of a rating
    /// that has had a chance to move off the 1200 start (which sits exactly
    /// on Gold's floor, where two early losses would read as a demotion).
    /// 0 shows a tier from the first match.
    var placementMatches: Int

    static let fallback = RatingTiers(
        tiers: [
            Tier(name: "Bronze", floor: SoloRating.minimum),
            Tier(name: "Silver", floor: 1000),
            Tier(name: "Gold", floor: 1200),
            Tier(name: "Platinum", floor: 1400),
            Tier(name: "Diamond", floor: 1600),
            Tier(name: "Master", floor: 1800),
            Tier(name: "Grandmaster", floor: 2000),
        ],
        divisionsPerTier: 4,
        demotionMargin: SoloRating.maxSwing + 1,
        unrankedUntil: SoloRatingService.freePuzzlesBeforeSignIn,
        placementMatches: 5
    )

    /// Parses the `rating_tiers` Remote Config payload:
    /// `{"tiers":[{"name":"Bronze","floor":100},…],"divisions":4,"demotionMargin":25,"unrankedUntil":10,"placementMatches":5}`.
    /// Anything missing or malformed keeps the shipped value; a tier list
    /// is only taken if it has at least two strictly ascending entries.
    init(json: [String: Any]?) {
        self = .fallback
        guard let json else { return }
        if let raw = json["tiers"] as? [[String: Any]] {
            let parsed = raw.compactMap { entry -> Tier? in
                guard let name = entry["name"] as? String, !name.isEmpty,
                      let floor = (entry["floor"] as? NSNumber)?.intValue else { return nil }
                return Tier(name: name, floor: floor)
            }
            let ascending = zip(parsed, parsed.dropFirst()).allSatisfy { $0.floor < $1.floor }
            if parsed.count == raw.count, parsed.count >= 2, ascending {
                tiers = parsed
            }
        }
        if let divisions = (json["divisions"] as? NSNumber)?.intValue, (1...6).contains(divisions) {
            divisionsPerTier = divisions
        }
        if let margin = (json["demotionMargin"] as? NSNumber)?.intValue, (0...200).contains(margin) {
            demotionMargin = margin
        }
        if let until = (json["unrankedUntil"] as? NSNumber)?.intValue, (0...100).contains(until) {
            unrankedUntil = until
        }
        if let placement = (json["placementMatches"] as? NSNumber)?.intValue, (0...50).contains(placement) {
            placementMatches = placement
        }
    }

    private init(tiers: [Tier], divisionsPerTier: Int, demotionMargin: Int, unrankedUntil: Int, placementMatches: Int) {
        self.tiers = tiers
        self.divisionsPerTier = divisionsPerTier
        self.demotionMargin = demotionMargin
        self.unrankedUntil = unrankedUntil
        self.placementMatches = placementMatches
    }

    /// Whether a ranked profile has finished placement. A stored held tier
    /// counts as placed regardless of the counter: players who were shown a
    /// badge before placement existed keep it.
    func hasPlaced(rankedMatches: Int, rankedTier: Int?) -> Bool {
        rankedTier != nil || rankedMatches >= placementMatches
    }

    // MARK: Lookup

    /// Index of the tier a rating falls in with no hysteresis.
    func rawTier(for rating: Int) -> Int {
        max(0, (tiers.lastIndex { rating >= $0.floor }) ?? 0)
    }

    /// Tier to display for `rating` when the player was last shown `held`:
    /// promotions are immediate, demotions wait for the margin.
    func heldTier(for rating: Int, held: Int?) -> Int {
        let raw = rawTier(for: rating)
        guard let held, held > raw, tiers.indices.contains(held) else { return raw }
        return rating > tiers[held].floor - demotionMargin ? held : raw
    }

    func standing(rating: Int, held: Int?) -> TierStanding {
        let index = heldTier(for: rating, held: held)
        let tier = tiers[index]
        let isTop = index == tiers.count - 1
        guard !isTop else {
            return TierStanding(tierIndex: index, name: tier.name, division: nil,
                                rating: rating, progress: 1, pointsToNext: nil)
        }
        let next = tiers[index + 1].floor
        let width = Double(next - tier.floor) / Double(divisionsPerTier)
        // Held above the raw tier → bottom division, no negative progress.
        let offset = Double(max(0, rating - tier.floor))
        let slot = min(divisionsPerTier - 1, Int(offset / width))
        let division = divisionsPerTier - slot
        let divisionFloor = Double(tier.floor) + Double(slot) * width
        let divisionCeiling = divisionFloor + width
        let progress = min(1, max(0, (Double(rating) - divisionFloor) / width))
        let pointsToNext = max(1, Int(divisionCeiling.rounded(.up)) - rating)
        return TierStanding(tierIndex: index, name: tier.name, division: division,
                            rating: rating, progress: progress, pointsToNext: pointsToNext)
    }

    /// Name of the tier/division just above `standing`, for "28 to Gold I".
    func nextLabel(after standing: TierStanding) -> String? {
        guard let division = standing.division else { return nil }
        if division > 1 { return "\(standing.name) \(TierStanding.numeral(division - 1))" }
        guard standing.tierIndex + 1 < tiers.count else { return nil }
        let next = tiers[standing.tierIndex + 1]
        return standing.tierIndex + 2 == tiers.count ? next.name : "\(next.name) \(TierStanding.numeral(divisionsPerTier))"
    }
}

struct TierStanding: Equatable {
    let tierIndex: Int
    let name: String
    /// `nil` in the top tier.
    let division: Int?
    let rating: Int
    /// 0…1 through the current division (1 in the top tier).
    let progress: Double
    let pointsToNext: Int?

    /// "Gold II", or just the name in the top tier.
    var label: String {
        guard let division else { return name }
        return "\(name) \(Self.numeral(division))"
    }

    static func numeral(_ n: Int) -> String {
        switch n {
        case 1: return "I"
        case 2: return "II"
        case 3: return "III"
        case 4: return "IV"
        case 5: return "V"
        case 6: return "VI"
        default: return String(n)
        }
    }

    /// Badge color. Keyed on the tier name so a renamed/reordered remote
    /// table still gets sensible colors; unknown names fall back to the
    /// accent.
    @MainActor var color: Color {
        switch name.lowercased() {
        case "bronze": return Color(red: 0.72, green: 0.47, blue: 0.30)
        case "silver": return Color(red: 0.60, green: 0.63, blue: 0.68)
        case "gold": return Color(red: 0.85, green: 0.65, blue: 0.25)
        case "platinum": return Color(red: 0.42, green: 0.70, blue: 0.72)
        case "diamond": return Color(red: 0.45, green: 0.58, blue: 0.90)
        case "master": return Color(red: 0.62, green: 0.42, blue: 0.80)
        case "grandmaster": return Color(red: 0.85, green: 0.30, blue: 0.32)
        default: return Theme.accent
        }
    }
}

/// How a result moved the player's tier, for the promotion moment on the
/// result card. Division-only moves are not announced.
enum TierChange: Equatable {
    case promoted(TierStanding)
    case demoted(TierStanding)
    /// Placement just finished and this is the first badge ever shown.
    case placed(TierStanding)

    var standing: TierStanding {
        switch self {
        case .promoted(let s), .demoted(let s), .placed(let s): return s
        }
    }
}

// MARK: - Views

/// "◆ Gold II" chip. `showsRating` appends the number in muted ink.
struct TierChip: View {
    let standing: TierStanding?
    var showsRating = false
    var compact = false

    var body: some View {
        // Spacing is per-gap rather than uniform: the emblem wants a little air
        // from the label, but the rating should hug the label like a suffix —
        // a full gap there read as two separate pieces ("Silver IV   1017").
        HStack(spacing: 0) {
            Image(systemName: standing == nil ? "seal" : "seal.fill")
                .font(.system(size: compact ? 10 : 12, weight: .bold))
                .foregroundStyle(standing?.color ?? Theme.inkMuted)
            Text(standing?.label ?? "Unranked")
                .font(.system(compact ? .caption : .subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
                .padding(.leading, compact ? 4 : 6)
            if showsRating, let standing {
                Text(String(standing.rating))
                    .font(.system(compact ? .caption : .subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.leading, compact ? 2 : 3)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 4 : 8)
        .background(Theme.pill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Large badge for the Ranked hub and stats: emblem, tier label, rating and
/// a progress bar towards the next division.
struct TierBadge: View {
    let standing: TierStanding?
    let tiers: RatingTiers
    var caption = "YOUR RATING"
    /// Shown under an "Unranked" label: why there is no badge yet
    /// ("Placement match 2 of 5", "Invite a friend to reveal it").
    var unrankedDetail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(caption)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)
            Image(systemName: standing == nil ? "seal" : "seal.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(standing?.color ?? Theme.inkMuted)
                .shadow(color: (standing?.color ?? .clear).opacity(0.35), radius: 10, y: 4)
            Text(standing?.label ?? "Unranked")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark)
            if standing == nil, let unrankedDetail {
                Text(unrankedDetail)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            if let standing {
                Text(String(standing.rating))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                if let next = tiers.nextLabel(after: standing), let points = standing.pointsToNext {
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.pill)
                                Capsule().fill(standing.color)
                                    .frame(width: max(8, geo.size.width * standing.progress))
                            }
                        }
                        .frame(height: 8)
                        Text("\(points) to \(next)")
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }
}

/// One-line tier readout under a rating delta: "Gold II · 28 to Gold I",
/// or the promotion / demotion announcement when the tier moved.
struct TierResultLine: View {
    let standing: TierStanding?
    let change: TierChange?
    let tiers: RatingTiers
    /// Replaces the badge line while the player is still placing.
    var placementNote: String? = nil

    var body: some View {
        if let change {
            HStack(spacing: 6) {
                Image(systemName: "seal.fill")
                    .foregroundStyle(change.standing.color)
                Text(changeText(change))
                    .foregroundStyle(demoted ? .red.opacity(0.85) : Theme.inkDark)
            }
            .font(.system(.subheadline, design: .rounded, weight: .heavy))
            .transition(.scale.combined(with: .opacity))
        } else if let standing {
            HStack(spacing: 6) {
                Image(systemName: "seal.fill")
                    .foregroundStyle(standing.color)
                Text(standing.label)
                    .foregroundStyle(Theme.inkDark)
                if let next = tiers.nextLabel(after: standing), let points = standing.pointsToNext {
                    Text("· \(points) to \(next)")
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else if let placementNote {
            HStack(spacing: 6) {
                Image(systemName: "seal")
                    .foregroundStyle(Theme.inkMuted)
                Text(placementNote)
                    .foregroundStyle(Theme.inkMuted)
            }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func changeText(_ change: TierChange) -> String {
        switch change {
        case .promoted(let s): return "Promoted to \(s.name)!"
        case .demoted(let s): return "Demoted to \(s.name)"
        case .placed(let s): return "Placed in \(s.label)!"
        }
    }

    private var demoted: Bool {
        if case .demoted = change { return true }
        return false
    }
}
