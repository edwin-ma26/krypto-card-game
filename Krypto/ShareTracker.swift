import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// Append-only log of completed shares, so the referral push can actually be
/// measured rather than guessed at.
///
/// Two things this deliberately is *not*:
///
/// - It is not a counter document. A single doc with `FieldValue.increment`
///   would need public update access, and anyone could then set it to whatever
///   they liked. Separate docs mean a spammer can only add noise, never rewrite
///   history — and you can always filter noise out after the fact.
/// - It is not install attribution. Nothing here proves a share *became* a
///   signup; the coming-soon screen is shown signed-out, so there's usually no
///   code to tie the two ends together. Treat these as "shares sent". Real
///   attribution needs the existing referral-code flow, or a deferred deep link
///   on the landing page.
enum ShareTracker {
    @MainActor
    static func logCompletedShare(surface: String) {
        var event: [String: Any] = [
            "surface": surface,
            "createdAt": FieldValue.serverTimestamp(),
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
        ]
        // Lets you separate "200 shares" from "200 people shared" — without it,
        // one enthusiast hammering Share Again looks like traction.
        if let deviceId = UIDevice.current.identifierForVendor?.uuidString {
            event["deviceId"] = deviceId
        }
        // Only present when they happen to be signed in; the pre-launch screen
        // usually isn't. When it is set, it's the one field that can tie a share
        // back to a real account.
        if let uid = Auth.auth().currentUser?.uid {
            event["uid"] = uid
        }

        let db = Firestore.firestore()
        // Fire-and-forget: a dropped metric must never cost the player their
        // badge or show them an error.
        Task.detached { try? await db.collection("shareEvents").addDocument(data: event) }
    }
}
