import Foundation
import FirebaseFirestore

/// Single Player's "beat the clock" rating. Every solo puzzle is scored as a
/// match against *the field* — everyone who has solved (or is estimated to
/// solve) that puzzle — rather than against a single opponent.
///
/// Model: a puzzle's solve times are log-normal with median `medianSeconds`
/// (blended from the device-side difficulty estimate and the real average,
/// see `PuzzleModel`) and a fixed spread `logSigma`. The field is defined to
/// play at `fieldRating`. A player's expected score is the usual Elo
/// expectation against the field; their actual score is the fraction of the
/// field they beat, read off that distribution at their time. That fraction
/// is turned into a *performance rating* — the rating for which it would be
/// exactly break-even — and the player's rating moves a fixed share of the
/// way toward it. The displayed target is the time whose performance equals
/// the current rating. (An earlier `k × (actual − expected)` form capped the
/// actual score at 1, so high ratings had nothing left to win and stalled
/// around 1700; the performance form keeps moving.)
///
/// Because the score is a percentile of the puzzle's *own* distribution,
/// puzzle difficulty moves the target time but not the stakes of a solve.
/// Giving up is the exception: its cost is set from difficulty directly (an
/// easy puzzle is more expensive to quit) and is independent of rating, and
/// a slow finish is always cheaper than quitting on the same puzzle.
enum SoloRating {
    static let initial = 1200
    static let fieldRating = 1200.0
    static let minimum = 100
    static let maximum = 3000
    /// Share of the gap to a solve's performance rating closed per puzzle.
    /// With `maxSwing` 24, any performance more than 300 points from the
    /// current rating is capped, so one freak solve can't move it too far.
    /// (0.1 felt twitchy: a finish at 1.5× target already took the full loss.)
    static let step = 0.08
    /// Largest move in either direction from one puzzle. Mirrored in the
    /// `users` rules, which refuse a `soloRating` write that jumps further.
    static let maxSwing = 24
    /// Spread of ln(solve time) within one puzzle. Eyeballed from the handful
    /// of puzzles with a dozen-plus solves (Nov 2026), whose times span about
    /// a factor of two either side of the middle at one sigma.
    static let logSigma = 0.7
    /// Real solves needed before the live average outweighs the estimate —
    /// the same prior `PuzzleStats.Summary.targetSeconds` uses.
    static let priorWeight = 20.0

    /// What the player is up against on one puzzle.
    struct PuzzleModel: Equatable {
        let medianSeconds: Double

        /// `estimateSeconds` is the device-side difficulty estimate
        /// (`Krypto.estimateSolveSeconds`); `summary` the live stats, if the
        /// fetch has returned. Shrinks the real average toward the estimate
        /// while there are few solves, exactly like the daily target.
        init(estimateSeconds: Int, summary: PuzzleStats.Summary?) {
            let estimate = Double(max(estimateSeconds, 1))
            guard let summary, summary.timesSolved > 0, let average = summary.averageSolveSeconds else {
                medianSeconds = estimate
                return
            }
            let realWeight = Double(summary.timesSolved) / (Double(summary.timesSolved) + priorWeight)
            medianSeconds = realWeight * Double(max(average, 1)) + (1 - realWeight) * estimate
        }

        init(medianSeconds: Double) { self.medianSeconds = medianSeconds }
    }

    /// Elo expectation of a `rating` player against the field.
    static func expectedScore(rating: Int) -> Double {
        1.0 / (1.0 + pow(10, (fieldRating - Double(rating)) / 400.0))
    }

    /// Share of the field slower than a solve of `seconds` on this puzzle.
    /// Fractional seconds matter here: at a 17-second target a whole second
    /// is worth several rating points, so callers pass the exact solve time.
    static func fractionBeaten(seconds: Double, model: PuzzleModel) -> Double {
        let t = max(seconds, 0.1)
        let z = (log(t) - log(model.medianSeconds)) / logSigma
        // P(T > t) for a log-normal: upper tail of the standard normal at z.
        return 0.5 * erfc(z / 2.0.squareRoot())
    }

    /// The rating for which beating `fraction` of the field is break-even:
    /// the Elo expectation run backwards. 50% → 1200, 90% → ~1580, 99% → ~2000.
    /// Clamped away from 0 and 1 so an extreme time stays finite.
    static func performanceRating(fractionBeaten fraction: Double) -> Double {
        let p = min(0.999, max(0.001, fraction))
        return fieldRating + 400 * log10(p / (1 - p))
    }

    /// Break-even time: finish faster and you gain, slower and you lose.
    /// Performance equals rating exactly where the fraction beaten equals
    /// the Elo expectation, so this is the same time as before.
    static func targetSeconds(rating: Int, model: PuzzleModel) -> Int {
        let expected = expectedScore(rating: rating)
        // `fractionBeaten` falls monotonically with time, so bisect on it.
        var low = 0.1, high = 3600.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fractionBeaten(seconds: mid, model: model) > expected { low = mid } else { high = mid }
        }
        return max(1, Int(((low + high) / 2).rounded()))
    }

    /// Points lost for showing the solution instead of finishing. Set by
    /// difficulty alone: 15 at a one-minute median, about 7 more or fewer
    /// for every halving or doubling of the median, within 5…`maxSwing`.
    static func giveUpCost(model: PuzzleModel) -> Int {
        let raw = 15.0 - 7.5 * log2(model.medianSeconds / 60.0)
        return min(maxSwing, max(5, Int(raw.rounded())))
    }

    /// Rating change for a finished solve: `step` of the way toward the
    /// solve's performance rating. Clamped to ±`maxSwing`, and the loss is
    /// additionally held just under this puzzle's give-up cost so finishing
    /// late is never worse than quitting.
    static func solveDelta(rating: Int, seconds: Double, model: PuzzleModel) -> Int {
        let performance = performanceRating(fractionBeaten: fractionBeaten(seconds: seconds, model: model))
        let raw = Int((step * (performance - Double(rating))).rounded())
        let floor = -(giveUpCost(model: model) - 1)
        return min(maxSwing, max(floor, raw))
    }

    static func clamp(_ rating: Int) -> Int { min(maximum, max(minimum, rating)) }
}

/// Owns the player's solo rating: a device-local copy for everyone, mirrored
/// to `users/{uid}.soloRating` once signed in. Also counts completed solo
/// puzzles for the signed-out sign-in gate.
///
/// The client computes and writes its own rating (as Ranked does today), so
/// this is a personal number, not a leaderboard-grade one; the `users` rules
/// bound each write to `SoloRating.maxSwing` so it can't be set arbitrarily
/// in one request.
@MainActor
final class SoloRatingService: ObservableObject {
    // Persisted by hand rather than via `@AppStorage`, which doesn't publish
    // changes from inside an `ObservableObject`.
    @Published private(set) var rating: Int {
        didSet { UserDefaults.standard.set(rating, forKey: "soloRating") }
    }
    /// Completed solo puzzles (solved or given up) on this device, across
    /// sign-in state. Drives `needsSignIn`.
    @Published private(set) var puzzlesCompleted: Int {
        didSet { UserDefaults.standard.set(puzzlesCompleted, forKey: "soloPuzzlesCompleted") }
    }
    /// Rating change from the most recent completed puzzle, for the result card.
    @Published private(set) var lastDelta: Int?
    /// Tier the player was last shown. Kept separately from `rating` so a
    /// dip just under a tier floor doesn't demote them (see `RatingTiers`).
    /// Mirrored to `users/{uid}.soloTier`.
    @Published private(set) var heldTier: Int? {
        didSet { UserDefaults.standard.set(heldTier, forKey: "soloTier") }
    }
    /// Promotion / demotion from the most recent completed puzzle, if any.
    @Published private(set) var lastTierChange: TierChange?

    /// Signed-out players get this many puzzles before the result screen
    /// asks them to sign in to keep going.
    static let freePuzzlesBeforeSignIn = 10
    static let field = "soloRating"
    static let tierField = "soloTier"

    private let db = Firestore.firestore()
    private var uid: String?
    /// True while the device holds a rating change the profile hasn't
    /// confirmed: applied before sign-in, or written but not yet acknowledged.
    /// `bind` then pushes the local value instead of reading the profile's,
    /// so a sync racing a fresh result can't roll it back.
    private var hasUnsyncedChange = false

    private var accountDeletedObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        rating = defaults.object(forKey: "soloRating") as? Int ?? SoloRating.initial
        puzzlesCompleted = defaults.integer(forKey: "soloPuzzlesCompleted")
        heldTier = defaults.object(forKey: "soloTier") as? Int
        accountDeletedObserver = NotificationCenter.default.addObserver(
            forName: AuthService.accountDeletedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetToUnrated() }
        }
    }

    /// Back to a fresh device after the account was deleted (the defaults
    /// were already cleared by `AuthService`; this resets the live values).
    private func resetToUnrated() {
        hasUnsyncedChange = false
        lastDelta = nil
        lastTierChange = nil
        rating = SoloRating.initial
        puzzlesCompleted = 0
        heldTier = nil
    }

    private var tiers: RatingTiers { Remote.shared.tiers }

    /// Tier badge to show, or `nil` while the player is still Unranked
    /// (fewer than `RatingTiers.unrankedUntil` rated puzzles on this device).
    var standing: TierStanding? {
        guard puzzlesCompleted >= tiers.unrankedUntil else { return nil }
        return tiers.standing(rating: rating, held: heldTier)
    }

    func needsSignIn(isSignedIn: Bool) -> Bool {
        !isSignedIn && puzzlesCompleted >= Self.freePuzzlesBeforeSignIn
    }

    /// Call when the signed-in user changes. Prefers the profile's stored
    /// rating; a profile that has never had one inherits this device's, so a
    /// player who built up a rating before signing in keeps it.
    func bind(uid: String?) async {
        self.uid = uid
        guard let uid else { return }
        let ref = db.collection("users").document(uid)
        if hasUnsyncedChange {
            if (try? await ref.updateData(syncPayload)) != nil { hasUnsyncedChange = false }
            return
        }
        guard let data = try? await ref.getDocument().data() else { return }
        if let stored = data[Self.field] as? Int {
            rating = SoloRating.clamp(stored)
            heldTier = data[Self.tierField] as? Int ?? tiers.rawTier(for: rating)
        } else if rating != SoloRating.initial {
            try? await ref.updateData(syncPayload)
        }
    }

    func recordSolve(seconds: Double, model: SoloRating.PuzzleModel) {
        apply(delta: SoloRating.solveDelta(rating: rating, seconds: seconds, model: model))
    }

    func recordGiveUp(model: SoloRating.PuzzleModel) {
        apply(delta: -SoloRating.giveUpCost(model: model))
    }

    /// A puzzle the process died on (swiped away); `cost` was captured when
    /// it was saved. Same accounting as a give-up.
    func recordAbandonment(cost: Int) {
        apply(delta: -max(0, cost))
    }

    private var syncPayload: [String: Any] {
        var payload: [String: Any] = [Self.field: rating]
        if let heldTier { payload[Self.tierField] = heldTier }
        return payload
    }

    private func apply(delta: Int) {
        let updated = SoloRating.clamp(rating + delta)
        lastDelta = updated - rating
        // Without a stored tier the player has been shown the band of the
        // current rating; treat that as held so the first dip under a floor
        // gets the same margin as any other.
        let heldBefore = heldTier ?? tiers.rawTier(for: rating)
        let before = standing
        rating = updated
        puzzlesCompleted += 1
        // Promote at the floor, demote only past the margin; division moves
        // aren't announced.
        heldTier = tiers.heldTier(for: updated, held: heldBefore)
        if let before, let after = standing, after.tierIndex != before.tierIndex {
            lastTierChange = after.tierIndex > before.tierIndex ? .promoted(after) : .demoted(after)
        } else {
            lastTierChange = nil
        }
        hasUnsyncedChange = true
        guard let uid else { return }
        // `updateData` rather than a merge-set: the profile doc always exists
        // for a signed-in user, and the rules clamp the per-write move.
        db.collection("users").document(uid).updateData(syncPayload) { [weak self] error in
            if let error {
                print("SoloRating write failed: \(error.localizedDescription)")
            } else if self?.rating == updated {
                self?.hasUnsyncedChange = false
            }
        }
    }
}
