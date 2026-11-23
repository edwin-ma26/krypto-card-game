import SwiftUI
import FirebaseFirestore

/// The app's entry screen: pick a mode, then drop into it full-screen. Replaces
/// the old design where every mode lived behind its own icon in the solo
/// board's top bar — that read as clutter once Daily Puzzle and Ranked joined
/// Multiplayer and Competition there. Each mode screen now carries its own way
/// back here (see `dismiss` calls in those views) rather than this view owning
/// shared navigation state.
struct HomeView: View {
    @StateObject private var remote = Remote.shared
    @StateObject private var userCount = UserCountService()
    // Owned here (rather than by Daily Puzzle alone) so the profile button is
    // reachable from this mode-selection screen too, using the same signed-in
    // session/friends list Daily Puzzle's streak and profile sheet rely on.
    @StateObject private var auth = AuthService()
    @StateObject private var friends = FriendsService()
    // Shared so a finished match's rematch request can reach this screen (and
    // the banner on every mode screen) after Competition has been closed.
    @StateObject private var ranked = RankedService.shared

    @State private var showSinglePlayer = false
    @State private var showMultiplayer = false
    @State private var showDailyPuzzle = false
    @State private var showRanked = false
    // "NEW" pill on the Ranked card, shown from the moment Ranked unlocks until
    // the player opens it once, so launch-day attention doesn't turn into
    // permanent clutter.
    @AppStorage("hasOpenedRanked") private var hasOpenedRanked = false
    @State private var showHowToPlay = false
    @State private var showProfile = false

    // Tier chips on the Single Player and Ranked cards. Solo comes from the
    // device copy `SoloRatingService` keeps; Ranked is read off the profile
    // doc once per sign-in (`-1` = no held tier stored yet).
    @AppStorage("soloRating") private var soloRating = SoloRating.initial
    @AppStorage("soloTier") private var soloTier = -1
    @AppStorage("soloPuzzlesCompleted") private var soloPuzzlesCompleted = 0
    @State private var rankedStanding: TierStanding?

    private var soloStanding: TierStanding? {
        guard soloPuzzlesCompleted >= remote.tiers.unrankedUntil else { return nil }
        return remote.tiers.standing(rating: soloRating, held: soloTier >= 0 ? soloTier : nil)
    }

    // First-launch walkthrough. Shown once; `onTryItOut` drops the player
    // straight into Single Player via `launchSinglePlayerAfterOnboarding`, which
    // the cover's `onDismiss` reads so the two full-screen covers don't try to
    // present in the same frame.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var launchSinglePlayerAfterOnboarding = false

    // Soft update nudge. Dismissible, and shown at most once per recommended
    // build — `lastDismissedUpdateBuild` records the build we last nagged about
    // so a "Later" survives relaunches until the console bumps the target again.
    // The hard `min_supported_build` gate lives in `KryptoApp` and takes over
    // entirely when it trips.
    @AppStorage("lastDismissedUpdateBuild") private var lastDismissedUpdateBuild = 0
    @State private var showSoftUpdate = false
    @Environment(\.openURL) private var openURL

    /// Set when a friend challenge is accepted from this screen — presents the
    /// game full-screen and joins the challenge room on appear.
    @State private var challengeRoom: ChallengeRoom?

    private struct ChallengeRoom: Identifiable {
        let id = UUID()
        let code: String
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // The mode cards plus header are taller than an iPhone SE screen. A
            // plain VStack overflows symmetrically, which pushes the logo under
            // the status bar and the profile button off the top entirely. Host
            // it in a ScrollView at least as tall as the screen: unchanged where
            // it fits, scrolls where it doesn't.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        Spacer(minLength: 16)

                        VStack(spacing: 10) {
                            Image("KryptoLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Text("Krypto!")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.inkDark)
                            Text("Combine the cards to hit the target.")
                                .font(.system(.callout, design: .rounded, weight: .medium))
                                .foregroundStyle(Theme.inkMuted)
                        }

                        VStack(spacing: 16) {
                            if remote.flags.dailyPuzzleEnabled {
                                modeCard(
                                    title: "Daily Puzzle",
                                    subtitle: "One puzzle a day. Keep your streak alive.",
                                    systemImage: "flame.fill"
                                ) { showDailyPuzzle = true }
                            }

                            modeCard(
                                title: "Single Player",
                                subtitle: "Play solo on one device, at your own pace.",
                                systemImage: "person.fill",
                                badge: .some(soloStanding)
                            ) { showSinglePlayer = true }

                            if remote.flags.multiplayerEnabled {
                                modeCard(
                                    title: "Multiplayer",
                                    subtitle: "Race a friend — on one phone, or across devices.",
                                    systemImage: "person.2.fill"
                                ) { showMultiplayer = true }
                            }

                            if remote.flags.competitionEnabled {
                                rankedCard
                            }
                        }
                        .padding(.horizontal, 24)

                        Spacer()

                        Button { showHowToPlay = true } label: {
                            Label("How to Play", systemImage: "questionmark.circle.fill")
                                .font(.system(.footnote, design: .rounded, weight: .bold))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { showProfile = true } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(10)
                            .background(Theme.pill, in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                // Sit clear of the status bar glyphs rather than hugging them;
                // the logo column below shares the same inset.
                .padding(.top, 16)
                Spacer()
            }
        }
        .overlay { ReferralThanksOverlay(auth: auth) }
        .overlay(alignment: .top) {
            IncomingAlertsView(
                friends: friends,
                onAcceptChallenge: { challenge in
                    let code = challenge.roomCode
                    friends.clearIncomingChallenge()
                    challengeRoom = ChallengeRoom(code: code)
                },
                onOpenFriendRequests: { showProfile = true },
                onAcceptRankedRematch: { showRanked = true }
            )
            // Clear the profile button in the top-right corner.
            .padding(.top, 44)
        }
        .task { await userCount.refresh(target: remote.flags.competitionUnlockThreshold) }
        // Establish an anonymous session on first launch so a player who
        // shares before signing up still has a uid — and therefore a
        // referral code — to attribute invites to. Upgraded in place if they
        // later create a real account.
        .task { await auth.ensureSignedIn() }
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            } else {
                maybeShowSoftUpdate()
            }
        }
        // Config lands behind the splash before this view's first paint, but a
        // later scene-active refresh can raise the recommended build mid-session;
        // re-check whenever an activation bumps the generation.
        .onChange(of: remote.generation) { _, _ in maybeShowSoftUpdate() }
        .onChange(of: auth.user?.uid) { _, uid in
            if let uid {
                friends.start(uid: uid)
                Task { await friends.loadFriends(uid: uid) }
            } else {
                friends.stop()
                ranked.reset()
            }
        }
        // A rematch accepted from a banner inside another mode: that screen
        // dismisses itself, and Competition is presented from its cover's
        // `onDismiss` (below) so the two covers never swap in one frame.
        .onChange(of: ranked.wantsCompetitionScreen) { _, wants in
            if wants, !showSinglePlayer, !showMultiplayer, !showDailyPuzzle, challengeRoom == nil {
                openCompetitionForRematch()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
            if launchSinglePlayerAfterOnboarding {
                launchSinglePlayerAfterOnboarding = false
                showSinglePlayer = true
            }
        }) {
            OnboardingView(
                onTryItOut: {
                    hasCompletedOnboarding = true
                    launchSinglePlayerAfterOnboarding = true
                    showOnboarding = false
                },
                onSkip: {
                    hasCompletedOnboarding = true
                    showOnboarding = false
                }
            )
        }
        .fullScreenCover(isPresented: $showSinglePlayer, onDismiss: openCompetitionForRematch) { ContentView() }
        .fullScreenCover(item: $challengeRoom, onDismiss: openCompetitionForRematch) { room in
            ContentView(joinRoomOnLaunch: room.code)
        }
        .fullScreenCover(isPresented: $showMultiplayer, onDismiss: openCompetitionForRematch) {
            MultiplayerHubView(auth: auth, friends: friends)
        }
        .fullScreenCover(isPresented: $showDailyPuzzle, onDismiss: openCompetitionForRematch) {
            DailyPuzzleView(auth: auth, friends: friends)
        }
        .fullScreenCover(isPresented: $showRanked) { CompetitionView() }
        .sheet(isPresented: $showHowToPlay) { HowToPlayView() }
        .sheet(isPresented: $showProfile) { ProfileView(auth: auth, friends: friends) }
        .sheet(isPresented: $showSoftUpdate, onDismiss: {
            // Record it on every dismissal path — Later, Update, or a swipe —
            // so the nudge doesn't return next launch for the same build.
            lastDismissedUpdateBuild = remote.flags.latestRecommendedBuild
        }) {
            SoftUpdateView(
                message: remote.flags.softUpdateMessage,
                onUpdate: {
                    if let url = URL(string: AppLinks.appStore) { openURL(url) }
                    showSoftUpdate = false
                },
                onLater: { showSoftUpdate = false }
            )
        }
    }

    /// Presents Competition if a rematch was just accepted from a banner on
    /// another screen; a no-op otherwise, so it's safe as every cover's
    /// `onDismiss`.
    private func openCompetitionForRematch() {
        guard ranked.wantsCompetitionScreen else { return }
        ranked.wantsCompetitionScreen = false
        showRanked = true
    }

    /// Shows the soft-update nudge when a newer build is recommended and we
    /// haven't already nagged about that build. Never fires over onboarding.
    private func maybeShowSoftUpdate() {
        guard hasCompletedOnboarding, !showOnboarding, !showSoftUpdate else { return }
        guard remote.recommendsUpdate,
              lastDismissedUpdateBuild < remote.flags.latestRecommendedBuild else { return }
        showSoftUpdate = true
    }

    // MARK: - Ranked card

    /// Ranked's unlock gate lives inside `CompetitionView` already (it flips
    /// from a "coming soon" progress screen to the real thing once enough
    /// players have signed up) — this just surfaces that same count on the
    /// card itself so it's visible before tapping in.
    private var isRankedUnlocked: Bool {
        remote.flags.competitionForceUnlock
            || (userCount.count ?? 0) >= remote.flags.competitionUnlockThreshold
    }

    private var rankedCard: some View {
        Button {
            if isRankedUnlocked { hasOpenedRanked = true }
            showRanked = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Ranked")
                            .font(.system(.title3, design: .rounded, weight: .heavy))
                            .foregroundStyle(Theme.inkDark)
                        if !isRankedUnlocked {
                            Text("COMING SOON")
                                .font(.system(.caption2, design: .rounded, weight: .heavy))
                                .kerning(0.5)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        } else if !hasOpenedRanked {
                            Text("NEW")
                                .font(.system(.caption2, design: .rounded, weight: .heavy))
                                .kerning(0.5)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    Text(rankedSubtitle)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isRankedUnlocked, let rankedStanding {
                        TierChip(standing: rankedStanding, showsRating: true, compact: true)
                            .padding(.top, 4)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.5))
            }
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        }
        .task(id: auth.user?.uid) {
            guard let uid = auth.user?.uid else { rankedStanding = nil; return }
            let data = try? await Firestore.firestore().collection("users").document(uid).getDocument().data()
            // No stored tier means the player hasn't placed (or hasn't revealed
            // their rank yet): the chip stays "Unranked".
            guard let elo = data?["elo"] as? Int, let held = data?["rankedTier"] as? Int else { rankedStanding = nil; return }
            rankedStanding = remote.tiers.standing(rating: elo, held: held)
        }
    }

    private var rankedSubtitle: String {
        guard !isRankedUnlocked else { return "Climb the leaderboard against real opponents." }
        let target = remote.flags.competitionUnlockThreshold
        guard let count = userCount.count else { return "Unlocks at \(target) players." }
        return "\(min(count, target))/\(target) players reached"
    }

    // MARK: - Mode card

    /// `badge`: `nil` shows no chip; `.some(nil)` shows "Unranked".
    private func modeCard(
        title: String,
        subtitle: String,
        systemImage: String,
        badge: TierStanding?? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(Theme.inkDark)
                    Text(subtitle)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        TierChip(standing: badge, showsRating: true, compact: true)
                            .padding(.top, 4)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.5))
            }
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        }
    }
}

#Preview {
    HomeView()
}
