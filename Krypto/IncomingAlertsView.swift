import SwiftUI

/// The stack of top-anchored alert banners — incoming friend challenge, incoming
/// friend request, a ranked opponent's rematch request, and the friends error toast. Rendered on both `HomeView` and
/// `ContentView` so an alert that arrives while the player sits on the main menu
/// shows up there too, not only once they're inside a game.
///
/// Both notification banners act on a whole-banner tap, like a system
/// notification: the challenge routes into the game, the friend request opens
/// the Friends section in Profile to accept or decline there.
struct IncomingAlertsView: View {
    @ObservedObject var friends: FriendsService
    /// Hide the challenge banner while it can't be acted on — e.g. mid-race in
    /// `ContentView`.
    var suppressChallenge = false
    /// Tapped the challenge banner: join the room. The caller decides what that
    /// means — join in place (`ContentView`) or launch into a game (`HomeView`).
    var onAcceptChallenge: (IncomingChallenge) -> Void
    /// Tapped the friend-request banner: open the Friends section in Profile.
    var onOpenFriendRequests: () -> Void
    /// Accepted a ranked rematch from the banner (the service has already
    /// queued): get the player to the Competition screen.
    var onAcceptRankedRematch: () -> Void

    /// Friend requests the player swiped away this session. The request still
    /// stands server-side (decline happens in Profile); this just clears the
    /// banner. Stale ids that the live list no longer contains are harmless.
    @State private var dismissedRequestIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 8) {
            challengeBanner
            friendRequestBanner
            RankedRematchBanner(onAccept: onAcceptRankedRematch)
            errorBanner
        }
        .animation(.easeInOut(duration: 0.25), value: friends.incomingChallenge != nil)
        .animation(.easeInOut(duration: 0.25), value: friends.incomingFriendRequests)
        .animation(.easeInOut(duration: 0.25), value: dismissedRequestIDs)
        .animation(.easeInOut(duration: 0.25), value: friends.errorMessage)
        .animation(.easeInOut(duration: 0.25), value: ranked.hasIncomingRematchBanner)
    }

    @ObservedObject private var ranked = RankedService.shared

    @ViewBuilder
    private var challengeBanner: some View {
        if let challenge = friends.incomingChallenge, !suppressChallenge {
            AlertBannerCard(
                icon: "person.2.fill",
                title: "\(challenge.fromName) challenged you!",
                subtitle: "Tap to join the game",
                hasFoundingPup: challenge.hasFoundingPup,
                badgeStage: challenge.badgeStage,
                onTap: { onAcceptChallenge(challenge) },
                onDismiss: { friends.clearIncomingChallenge() }
            )
        }
    }

    @ViewBuilder
    private var friendRequestBanner: some View {
        let pending = friends.incomingFriendRequests.first { !dismissedRequestIDs.contains($0.id) }
        if let request = pending {
            AlertBannerCard(
                icon: "person.fill.badge.plus",
                title: "\(request.fromName) wants to be friends",
                subtitle: "Tap to review in Profile",
                hasFoundingPup: request.hasFoundingPup,
                badgeStage: request.badgeStage,
                onTap: onOpenFriendRequests,
                onDismiss: { dismissedRequestIDs.insert(request.id) }
            )
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = friends.errorMessage {
            HStack(spacing: 10) {
                Text(message)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    friends.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
