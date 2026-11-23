import SwiftUI
import FirebaseFirestore

/// The one-shot "code redeemed" moment, shared across the screens a redemption
/// can happen on (Competition Mode's code field, and the sign-up form inside
/// the profile sheet). Redemption sites `post` it; whichever screen is on top
/// shows `ReferralThanksOverlay`, and dismissing clears it everywhere.
///
/// Lives outside `CompetitionService` because sign-up redeems just as the
/// auth listener dismisses the sign-up form: a message raised inside that
/// form would flash past unread, so the state has to outlive the view.
@MainActor
final class ReferralThanks: ObservableObject {
    static let shared = ReferralThanks()

    struct Pending: Equatable {
        let referrerUid: String
        let referrerName: String
        /// Already in this player's `friends` array, so the overlay offers no
        /// request (one would be refused as a duplicate anyway).
        let alreadyFriends: Bool
        /// This player's own username, read from Firestore rather than an
        /// `AuthService` cache: Competition Mode owns its own `AuthService`
        /// whose cache is never loaded, and sign-up may still be mid-write.
        let myName: String
    }

    @Published var pending: Pending?

    /// Call once `referrals/{myUid}` has been written. Looks up the referrer's
    /// display name so the overlay can name them; falls back to "your friend"
    /// if the profile can't be read.
    func post(referrerUid: String, myUid: String) async {
        let db = Firestore.firestore()
        let referrerDoc = try? await db.collection("users").document(referrerUid).getDocument()
        let name = (referrerDoc?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces)
        let myDoc = try? await db.collection("users").document(myUid).getDocument()
        let myFriends = myDoc?.data()?["friends"] as? [String] ?? []
        let myName = (myDoc?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        pending = Pending(
            referrerUid: referrerUid,
            referrerName: (name?.isEmpty == false) ? name! : "your friend",
            alreadyFriends: myFriends.contains(referrerUid),
            myName: myName
        )
    }

    func dismiss() {
        pending = nil
    }
}

/// Full-screen confirmation shown after a friend's code is redeemed, with a
/// one-tap friend request to the referrer. Styled like the board's confirm
/// overlays (see `ContentView.newGameConfirmOverlay`).
struct ReferralThanksOverlay: View {
    @ObservedObject var auth: AuthService
    @StateObject private var thanks = ReferralThanks.shared
    @State private var requestSent = false
    @State private var requestFailed = false

    var body: some View {
        ZStack {
            if let pending = thanks.pending {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { thanks.dismiss() }
                card(for: pending)
                    .padding(.horizontal, 28)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: thanks.pending)
        .onChange(of: thanks.pending) { _, pending in
            if pending == nil {
                requestSent = false
                requestFailed = false
            }
        }
    }

    /// Requests need a sender name; a provider sign-in that hasn't finished
    /// minting its handle yet would otherwise arrive as "Player". Prefer the
    /// name fetched at post time, then whatever this screen's auth has cached.
    private func senderName(for pending: ReferralThanks.Pending) -> String {
        let cached = auth.cachedDisplayName.trimmingCharacters(in: .whitespaces)
        return pending.myName.isEmpty ? cached : pending.myName
    }

    private func canSendRequest(for pending: ReferralThanks.Pending) -> Bool {
        auth.isSignedIn && !senderName(for: pending).isEmpty
    }

    private func card(for pending: ReferralThanks.Pending) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Code Redeemed!")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text(message(for: pending))
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            // Referral status is fetched when Competition Mode opens, not
            // streamed, so a referrer who already has it open sees nothing.
            Text("They'll see the credit the next time they open Competition Mode.")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if pending.alreadyFriends || requestSent {
                primaryButton("Done") { thanks.dismiss() }
            } else {
                HStack(spacing: 12) {
                    Button { thanks.dismiss() } label: {
                        Text("Not Now")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    primaryButton("Add Friend") { sendRequest(to: pending) }
                        .disabled(!canSendRequest(for: pending))
                        .opacity(canSendRequest(for: pending) ? 1 : 0.5)
                }
                if !canSendRequest(for: pending) {
                    Text("Set a username in your profile to add friends.")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 28).fill(.white).shadow(color: .black.opacity(0.15), radius: 20, y: 8))
    }

    private func message(for pending: ReferralThanks.Pending) -> String {
        let name = pending.referrerName
        if requestFailed {
            return "Couldn't send a friend request to \(name). You can add them from your profile later."
        }
        if requestSent {
            return "Friend request sent to \(name). You'll be friends once they accept."
        }
        if pending.alreadyFriends {
            return "You and \(name) both get credit for the referral."
        }
        return "You and \(name) both get credit. Want to add \(name) as a friend?"
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func sendRequest(to pending: ReferralThanks.Pending) {
        guard let myUid = auth.user?.uid else { return }
        let myName = senderName(for: pending)
        Task {
            do {
                try await FriendsService.sendFriendRequest(toUid: pending.referrerUid, myUid: myUid, myName: myName)
                requestSent = true
            } catch {
                requestFailed = true
            }
        }
    }
}
