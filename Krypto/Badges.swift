import Foundation
import FirebaseFirestore

/// The Founding Pup badge, earned by sharing before Competition Mode opens and
/// mutated further by each person who joins on your referral code.
///
/// It's earned on the pre-launch screen, which signed-out players can reach, so
/// the device is the only place it can be recorded at the moment it's won —
/// there may be no account to attach it to yet. `UserDefaults` therefore stays
/// the source of truth for *earning* it, and `sync` mirrors it onto the profile
/// doc as soon as a uid exists, which is what makes it visible to anybody else.
///
/// The mirror is one-way on purpose. A player who earned it on one device and
/// signs in on another gets the badge pushed up from wherever they earned it;
/// nothing ever clears the flag, because losing a badge to a stale device would
/// be worse than an extra write.
@MainActor
enum Badges {
    /// Matches the `@AppStorage` key on the pre-launch screen — same defaults
    /// store, so the two stay in step without a second source of truth.
    static let foundingPupDefaultsKey = "foundingPupBadgeEarned"
    private static let stageDefaultsKey = "foundingPupBadgeStage"

    /// Fields on `users/{uid}`. Owners may write `hasFoundingPup` on their own
    /// doc; `foundingPupStage` is locked to the `onReferralCreated` Cloud
    /// Function (Admin SDK) by the security rules, so it can't be forged.
    static let foundingPupField = "hasFoundingPup"
    static let stageField = "foundingPupStage"

    static var hasFoundingPup: Bool {
        get { UserDefaults.standard.bool(forKey: foundingPupDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: foundingPupDefaultsKey) }
    }

    /// Your own badge's evolution, cached so the profile can draw it instantly
    /// on open instead of waiting on a referral count that rarely changes.
    static var stage: BadgeStage {
        get { BadgeStage(rawValue: UserDefaults.standard.integer(forKey: stageDefaultsKey)) ?? .pup }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: stageDefaultsKey) }
    }

    /// Publishes the earned flag onto the signed-in profile and resolves the
    /// current evolution for local display. Safe to call on every profile
    /// load: it no-ops when there's nothing earned, and the write is
    /// idempotent otherwise.
    ///
    /// Two writers, on purpose:
    /// - `hasFoundingPup` is mirrored here, because the badge is earned offline
    ///   on the pre-launch screen and the device is the only witness.
    /// - `foundingPupStage` on the profile doc is owned by the
    ///   `onReferralCreated` Cloud Function, which recounts server-side the
    ///   moment a referral lands — so the referrer's dog evolves without
    ///   waiting for them to reopen this screen, and the number can't be
    ///   forged. This method still counts locally to redraw *this* device
    ///   instantly, but no longer pushes the stage to Firestore.
    ///
    /// Counting happens here rather than reusing `CompetitionService`'s
    /// `referralCount` because that only refreshes inside Competition Mode,
    /// which is still locked — the badge would never evolve until launch.
    @discardableResult
    static func sync(uid: String) async -> BadgeStage {
        guard hasFoundingPup else { return .pup }

        let db = Firestore.firestore()
        var resolved = stage
        // One aggregation query, billed as a single read at these volumes.
        if let snapshot = try? await db.collection("referrals")
            .whereField("referrerUid", isEqualTo: uid)
            .count
            .getAggregation(source: .server) {
            resolved = BadgeStage(referrals: Int(truncating: snapshot.count))
            stage = resolved
        }

        try? await db.collection("users").document(uid).setData([
            foundingPupField: true,
        ], merge: true)
        return resolved
    }
}
