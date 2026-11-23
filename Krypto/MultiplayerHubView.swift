import SwiftUI

/// The Multiplayer mode screen Home opens: the create/join picker with a Back
/// chevron, and nothing else. The board only appears once a match actually
/// starts, as a cover over this screen, and comes back here when it ends.
///
/// This owns the `MultiplayerService` for the whole visit so the room
/// survives the hop from picker to board, and so leaving mid-wait can tear
/// the room down rather than orphan it.
struct MultiplayerHubView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var friends: FriendsService
    @StateObject private var multiplayer = MultiplayerService()
    @Environment(\.dismiss) private var dismiss
    @State private var showBoard = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        // Backing out of a waiting room cancels it; a room
                        // with nobody in it would otherwise sit in Firestore.
                        if multiplayer.isActive { multiplayer.leave() }
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(10)
                            .background(Theme.pill, in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                MultiplayerView(service: multiplayer, auth: auth, friends: friends) {
                    showBoard = true
                }
            }
        }
        .overlay(alignment: .top) {
            RankedRematchBanner(onAccept: {
                if multiplayer.isActive { multiplayer.leave() }
                RankedService.shared.wantsCompetitionScreen = true
                dismiss()
            })
            .padding(.top, 44)
            .animation(.easeInOut(duration: 0.25), value: RankedService.shared.hasIncomingRematchBanner)
        }
        // A rematch accepted from the board underneath (`ContentView`) closes
        // that cover; close this one too so Home can present Competition.
        .onChange(of: RankedService.shared.wantsCompetitionScreen) { _, wants in
            if wants { dismiss() }
        }
        // The picker stamps `auth.multiplayerName` on rooms it creates or
        // joins; make sure the cached username is there to stamp.
        .task(id: auth.user?.uid) {
            if let uid = auth.user?.uid { await auth.loadProfile(uid: uid) }
        }
        .fullScreenCover(isPresented: $showBoard) {
            ContentView(multiplayer: multiplayer)
        }
        .onChange(of: showBoard) { _, shown in
            // The board's own back chevron can dismiss it mid-match. Leave the
            // room so this screen shows the picker again, not a blank
            // "playing" state.
            if !shown, multiplayer.isActive { multiplayer.leave() }
        }
    }
}
