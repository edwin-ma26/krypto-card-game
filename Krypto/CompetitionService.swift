import Foundation
import FirebaseFirestore

struct UserProfile: Equatable {
    var email: String
    var displayName: String
    var elo: Int
    /// Held tier index for the Ranked badge (see `RatingTiers`); `nil` until
    /// the first rated match writes one.
    var rankedTier: Int?
    /// Rated ranked matches finished, for placement (see
    /// `RatingTiers.placementMatches`). Incremented by the client with the
    /// Elo write after each match.
    var rankedMatches: Int
    var isPremium: Bool
    var premiumSource: String?  // "purchase" or "referral"
    var referralCode: String

    init(email: String, displayName: String, referralCode: String) {
        self.email = email
        self.displayName = displayName
        self.elo = 1200
        self.rankedMatches = 0
        self.isPremium = false
        self.premiumSource = nil
        self.referralCode = referralCode
    }

    init?(data: [String: Any]) {
        guard let email = data["email"] as? String,
              let displayName = data["displayName"] as? String,
              let elo = data["elo"] as? Int,
              let isPremium = data["isPremium"] as? Bool,
              let referralCode = data["referralCode"] as? String
        else { return nil }
        self.email = email
        self.displayName = displayName
        self.elo = elo
        self.rankedTier = data["rankedTier"] as? Int
        self.rankedMatches = data["rankedMatches"] as? Int ?? 0
        self.isPremium = isPremium
        self.premiumSource = data["premiumSource"] as? String
        self.referralCode = referralCode
    }

    var asDictionary: [String: Any] {
        [
            "email": email,
            "displayName": displayName,
            "elo": elo,
            "isPremium": isPremium,
            "premiumSource": premiumSource as Any,
            "referralCode": referralCode,
            "createdAt": FieldValue.serverTimestamp(),
        ]
    }
}

/// Unlock rule: pay once, OR refer 2 people, OR (if you were referred) refer just 1.
@MainActor
final class CompetitionService: ObservableObject {
    @Published var profile: UserProfile?
    @Published var referralCount = 0
    @Published var wasReferred = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let db = Firestore.firestore()
    private static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    var referralsNeededToUnlock: Int { wasReferred ? 1 : 2 }

    /// The per-player Ranked gate (`Remote.Flags.rankedReferralsRequired`):
    /// met once this player has referred at least `required` friends. A
    /// required count of 0 means the gate is switched off.
    func hasMetRankedReferralGate(required: Int, accountCreated: Date?, gateSince: Date?) -> Bool {
        if required <= 0 { return true }
        // Existing players are grandfathered: the gate is for sign-ups from
        // the cutoff day on.
        if let accountCreated, let gateSince, accountCreated < gateSince { return true }
        return referralCount >= required
    }

    func loadOrCreateProfile(uid: String, email: String, username: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        let ref = db.collection("users").document(uid)
        do {
            let snapshot = try await ref.getDocument()
            if let data = snapshot.data(), let existing = UserProfile(data: data) {
                profile = existing
            } else {
                let code = try await Self.generateUniqueReferralCode(uid: uid)
                let displayName = username?.isEmpty == false ? username! : (email.components(separatedBy: "@").first ?? "Player")
                let created = UserProfile(email: email, displayName: displayName, referralCode: code)
                // Merge: the doc usually already exists by now (username
                // reservation, friends, FCM token, solo rating all write to
                // it before Competition Mode is first opened), and a plain
                // set would wipe those fields.
                try await ref.setData(created.asDictionary, merge: true)
                profile = created
            }
            await refreshReferralStatus(uid: uid)
        } catch {
            errorMessage = "Couldn't load your profile. Check your connection."
        }
    }

    func refreshReferralStatus(uid: String) async {
        do {
            let countSnapshot = try await db.collection("referrals")
                .whereField("referrerUid", isEqualTo: uid)
                .count
                .getAggregation(source: .server)
            referralCount = Int(truncating: countSnapshot.count)

            let referredDoc = try await db.collection("referrals").document(uid).getDocument()
            wasReferred = referredDoc.exists

            await recomputeUnlock(uid: uid)
        } catch {
            // Non-fatal: leave last-known values in place.
        }
    }

    func redeemReferralCode(_ rawCode: String, uid: String) async {
        do {
            let referrerUid = try await Self.redeem(code: rawCode, uid: uid)
            await refreshReferralStatus(uid: uid)
            await ReferralThanks.shared.post(referrerUid: referrerUid, myUid: uid)
        } catch let error as ReferralError {
            errorMessage = error.message
        } catch {
            errorMessage = ReferralError.redeemFailed.message
        }
    }

    /// Looks up who owns `rawCode`, or nil if no such code exists.
    ///
    /// Sign-up calls this to validate a typed code *before* creating the
    /// account: once sign-up succeeds the view swaps straight to the signed-in
    /// profile, so an error raised afterwards would never be seen.
    static func referrerUid(forCode rawCode: String) async -> String? {
        let code = Self.normalize(rawCode)
        guard !code.isEmpty else { return nil }
        let doc = try? await Firestore.firestore().collection("referralCodes").document(code).getDocument()
        return doc?.data()?["uid"] as? String
    }

    /// The redemption itself, throwing rather than publishing, so callers
    /// outside Competition Mode can decide how (or whether) to surface a
    /// failure instead of inheriting this service's error banner. Returns
    /// the referrer's uid so the caller can thank them (`ReferralThanks`).
    @discardableResult
    static func redeem(code rawCode: String, uid: String) async throws -> String {
        let code = Self.normalize(rawCode)
        guard !code.isEmpty else { throw ReferralError.emptyCode }
        guard let referrerUid = await referrerUid(forCode: code) else {
            throw ReferralError.unknownCode
        }
        guard referrerUid != uid else { throw ReferralError.ownCode }
        do {
            try await Firestore.firestore().collection("referrals").document(uid).setData([
                "referrerUid": referrerUid,
                "referredUid": uid,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            // Rules make `referrals/{uid}` create-only, so the common cause here
            // is a second redemption attempt rather than a transient failure.
            throw ReferralError.redeemFailed
        }
        return referrerUid
    }

    private static func normalize(_ rawCode: String) -> String {
        rawCode.uppercased().trimmingCharacters(in: .whitespaces)
    }

    func recordPurchase(uid: String) async {
        do {
            try await db.collection("users").document(uid).updateData([
                "isPremium": true,
                "premiumSource": "purchase",
            ])
            profile?.isPremium = true
            profile?.premiumSource = "purchase"
        } catch {
            errorMessage = "Purchase succeeded but we couldn't unlock your account. Contact support."
        }
    }

    private func recomputeUnlock(uid: String) async {
        guard var profile, profile.premiumSource != "purchase" else { return }
        let unlockedByReferral = referralCount >= 2 || (wasReferred && referralCount >= 1)
        guard unlockedByReferral != profile.isPremium else { return }
        profile.isPremium = unlockedByReferral
        profile.premiumSource = unlockedByReferral ? "referral" : nil
        self.profile = profile
        try? await db.collection("users").document(uid).updateData([
            "isPremium": unlockedByReferral,
            "premiumSource": unlockedByReferral ? "referral" : FieldValue.delete(),
        ])
    }

    /// Returns `uid`'s referral code, minting and storing one if the account
    /// doesn't have it yet.
    ///
    /// Sign-up calls this because code generation used to live only in
    /// `loadOrCreateProfile`, which runs exclusively inside Competition Mode —
    /// locked until launch, so accounts created in the meantime got no code at
    /// all and had nothing to share. Idempotent, so it doubles as the backfill
    /// for accounts already in that state.
    static func ensureReferralCode(uid: String) async -> String? {
        let db = Firestore.firestore()
        let ref = db.collection("users").document(uid)
        if let existing = try? await ref.getDocument().data()?["referralCode"] as? String,
           !existing.isEmpty {
            return existing
        }
        guard let code = try? await generateUniqueReferralCode(uid: uid) else { return nil }
        try? await ref.setData(["referralCode": code], merge: true)
        return code
    }

    static func generateUniqueReferralCode(uid: String) async throws -> String {
        let db = Firestore.firestore()
        for _ in 0..<8 {
            let code = String((0..<6).map { _ in Self.codeAlphabet.randomElement()! })
            do {
                // Uniqueness is enforced by the rules, not by a read: the
                // `referralCodes` doc is create-only, so writing one that
                // already exists is rejected and we simply try another.
                try await db.collection("referralCodes").document(code).setData(["uid": uid])
                return code
            } catch {
                continue  // Collision (doc already exists) or transient error: try another code.
            }
        }
        throw NSError(
            domain: "Krypto", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't generate a referral code."]
        )
    }
}

/// User-facing failures from redeeming a referral code. Shared by Competition
/// Mode's redeem box and the sign-up forms so both describe the same problem
/// the same way.
enum ReferralError: Error {
    case emptyCode
    case unknownCode
    case ownCode
    case redeemFailed

    var message: String {
        switch self {
        case .emptyCode: return "Enter a code first."
        case .unknownCode: return "That referral code doesn't exist."
        case .ownCode: return "You can't redeem your own code."
        case .redeemFailed: return "Couldn't redeem that code \u{2014} you may have already used one."
        }
    }
}
