import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

// Paywall is disabled for launch: Competition/Ranked mode is free for everyone.
// Flip this back to true (and re-add ad gating if desired) to re-enable monetization.
let competitionPaywallEnabled = false

struct CompetitionView: View {
    @StateObject private var auth = AuthService()
    @StateObject private var competition = CompetitionService()
    @StateObject private var store = StoreKitManager()
    @StateObject private var ranked = RankedService.shared
    @StateObject private var userCount = UserCountService()
    @StateObject private var remote = Remote.shared
    @Environment(\.dismiss) private var dismiss

    /// Competition Mode opens once enough people have signed up, or immediately
    /// if the console forces it. This replaces the old hardcoded
    /// `competitionModeEnabled` constant, so the launch no longer needs a
    /// submission to trigger — but it stays closed by default, exactly as the
    /// constant did, until the count is actually met.
    private var isUnlocked: Bool {
        remote.flags.competitionForceUnlock
            || (userCount.count ?? 0) >= remote.flags.competitionUnlockThreshold
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if isUnlocked {
                    if auth.showsSignedInUI, let user = auth.user {
                        if competition.isLoading && competition.profile == nil {
                            ProgressView().tint(Theme.inkMuted)
                        } else {
                            CompetitionHomeView(uid: user.uid, competition: competition, store: store, ranked: ranked, auth: auth)
                                // Apple's "Hide My Email" and some providers can
                                // leave `email` nil; the profile tolerates "".
                                .task { await competition.loadOrCreateProfile(uid: user.uid, email: user.email ?? "", username: user.displayName) }
                        }
                    } else {
                        AuthSignInView(
                            auth: auth,
                            icon: "trophy.fill",
                            subtitle: "Sign in to get a global Elo rating, ranked matches, and early access to Competition Mode."
                        )
                    }
                } else {
                    ComingSoonView(userCount: userCount, target: remote.flags.competitionUnlockThreshold)
                }

                if ranked.phase == .searching {
                    SearchingPopup(ranked: ranked)
                        .transition(.opacity)
                }

                ReferralThanksOverlay(auth: auth)
            }
            // Accepting here stays on this screen: the searching popup above
            // shows while the matcher pairs the two players again.
            .overlay(alignment: .top) {
                RankedRematchBanner(onAccept: {})
                    .animation(.easeInOut(duration: 0.25), value: ranked.hasIncomingRematchBanner)
            }
            .onAppear { ranked.wantsCompetitionScreen = false }
            .animation(.easeInOut(duration: 0.2), value: ranked.phase)
            .navigationTitle("Competition Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
            }
            .task { await userCount.refresh(target: remote.flags.competitionUnlockThreshold) }
            .chooseUsernamePrompt(auth: auth)
            // The profile is loaded once on open; the rating card would
            // otherwise keep showing the pre-match number after a result.
            .onChange(of: ranked.newElo) { _, elo in
                if let elo {
                    competition.profile?.elo = elo
                    competition.profile?.rankedTier = ranked.myTier
                    competition.profile?.rankedMatches = ranked.matchesPlayed
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { isUnlocked && ranked.phase == .matched },
            set: { if !$0 { ranked.leave() } }
        )) {
            RankedMatchView(ranked: ranked)
        }
    }
}

// MARK: - Coming soon placeholder

private struct ComingSoonView: View {
    @ObservedObject var userCount: UserCountService
    let target: Int

    /// Device-local: there's no uid to hang it off on this screen, since the
    /// countdown is shown to signed-out players too. Reinstalling loses the
    /// badge, which is the tradeoff for it working before signup.
    @AppStorage("foundingPupBadgeEarned") private var badgeEarned = false
    @State private var isSharing = false
    @State private var stage = Badges.stage
    /// The signed-in player's referral code, blank when signed out. Without it
    /// a share can't be attributed, so the dog can't evolve from it either.
    @State private var myCode = ""

    private var progress: Double {
        guard let count = userCount.count, target > 0 else { return 0 }
        return min(1, max(0, Double(count) / Double(target)))
    }

    private var remaining: Int {
        max(0, target - (userCount.count ?? 0))
    }

    /// Carries the referral code when there is one. A bare link can't be
    /// credited to anybody — the recipient typing this code at sign-up is the
    /// only thing that registers a referral, and therefore the only thing that
    /// evolves the badge.
    private var shareMessage: String {
        myCode.isEmpty
            ? "Play Krypto! \(AppLinks.appStore)"
            : "Play Krypto! Use my code \(myCode) when you sign up: \(AppLinks.store(ref: myCode))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                progressCard
                badgeCard
            }
            .padding(20)
        }
        .task {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            myCode = await CompetitionService.ensureReferralCode(uid: uid) ?? ""
            stage = await Badges.sync(uid: uid)
        }
        .sheet(isPresented: $isSharing) {
            // A plain ShareLink can't tell us whether the share actually went
            // through, and a badge you get for tapping-then-cancelling isn't
            // much of a badge. The activity controller's completion handler can.
            ShareSheet(items: [shareMessage]) { completed in
                guard completed else { return }
                badgeEarned = true
                ShareTracker.logCompletedShare(surface: "competitionComingSoon")
                // Publish straight away when there's an account to attach it
                // to; otherwise the profile screen syncs it on next sign-in.
                if let uid = Auth.auth().currentUser?.uid {
                    Task { stage = await Badges.sync(uid: uid) }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Competitive Mode")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text("Ranked matches and Elo ratings unlock once \(target.formatted()) players have joined.")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding(.top, 12)
    }

    private var progressCard: some View {
        VStack(spacing: 14) {
            if let count = userCount.count {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(count.formatted())
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.inkDark)
                        .contentTransition(.numericText())
                    Text("/ \(target.formatted()) players")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
            } else {
                ProgressView()
                    .tint(Theme.inkMuted)
                    .frame(height: 52)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.pill)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.65)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        // `max(0, …)` because a zero-width capsule still renders
                        // its rounded caps, showing a stray dot at 0 players.
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 14)
            .animation(.easeOut(duration: 0.6), value: progress)

            Text(userCount.count == nil
                 ? "Counting players\u{2026}"
                 : "\(remaining.formatted()) more to go")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    private var badgeCard: some View {
        VStack(spacing: 14) {
            DogBadge(size: 128, isRevealed: badgeEarned, stage: stage)
                .padding(.top, 4)

            Text(badgeEarned ? stage.title : "\u{2605} TOP SECRET \u{2605}")
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .kerning(badgeEarned ? 0 : 1.5)
                .foregroundStyle(badgeEarned ? Theme.inkDark : Theme.accent)

            Text(badgeEarned
                 ? stage.blurb
                 : "There is an extremely cute dog hiding behind this badge. We're not showing you which one. Share Krypto to meet him \u{2014} and once Competition Mode opens, this badge is sealed forever.")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)

            if badgeEarned {
                if let hint = stage.nextHint {
                    Label(hint, systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                } else {
                    Label("Final form reached", systemImage: "sparkles")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Label("Ultra rare \u{00B7} pre-launch only", systemImage: "sparkles")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }

            Button {
                isSharing = true
            } label: {
                Label(badgeEarned ? "Share to Evolve Him" : "Share to Meet the Dog", systemImage: "square.and.arrow.up")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }
}

/// `UIActivityViewController` wrapper, used instead of `ShareLink` where the
/// caller needs to know whether the share was actually completed rather than
/// dismissed.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Home (signed in)

private struct CompetitionHomeView: View {
    let uid: String
    @ObservedObject var competition: CompetitionService
    @ObservedObject var store: StoreKitManager
    @ObservedObject var ranked: RankedService
    @ObservedObject var auth: AuthService
    @StateObject private var remote = Remote.shared
    @State private var referralInput = ""
    @State private var isRefreshingReferrals = false

    // MARK: Placement + referral gate

    /// Whether this player has finished their placement run (or was badged
    /// before placement existed).
    private var hasPlaced: Bool {
        guard let profile = competition.profile else { return false }
        return remote.tiers.hasPlaced(rankedMatches: profile.rankedMatches, rankedTier: profile.rankedTier)
    }

    private var hasMetReferralGate: Bool {
        competition.hasMetRankedReferralGate(
            required: remote.flags.rankedReferralsRequired,
            accountCreated: auth.user?.metadata.creationDate,
            gateSince: remote.flags.rankedReferralGateSince
        )
    }

    /// The referral card stands in the way of play when the gate is unmet
    /// and either it sits in front of the first match, or placement is over
    /// and the rank is waiting to be revealed.
    private var isBlockedByReferralGate: Bool {
        !hasMetReferralGate && (hasPlaced || !remote.flags.rankedGateAfterPlacement)
    }

    /// Placement done and gate met but no tier stored yet: the reveal was
    /// held back by the gate at the time (or the match that finished
    /// placement predates this build). Write the plain band now so every
    /// badge in the app lights up together.
    private func revealTierIfReady() async {
        guard var profile = competition.profile, profile.rankedTier == nil,
              hasPlaced, hasMetReferralGate else { return }
        let tier = remote.tiers.rawTier(for: profile.elo)
        profile.rankedTier = tier
        competition.profile = profile
        try? await Firestore.firestore().collection("users").document(uid)
            .updateData(["rankedTier": tier])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                eloCard

                if competitionPaywallEnabled, let profile = competition.profile, !profile.isPremium {
                    paywallCard
                    referralCard(
                        code: profile.referralCode,
                        needed: competition.referralsNeededToUnlock,
                        title: "Or unlock it free",
                        subtitle: competition.wasReferred
                            ? "You were referred \u{2014} refer just 1 more friend to unlock."
                            : "Refer 2 friends to unlock, free."
                    )
                } else if let profile = competition.profile, isBlockedByReferralGate {
                    // Ranked is open globally, but each player has to bring a
                    // friend (or `ranked_referrals_required` of them) — either
                    // before their first match, or once placement is done and
                    // their rank is waiting to be revealed.
                    let needed = remote.flags.rankedReferralsRequired
                    let friends = needed == 1 ? "a friend" : "\(needed) friends"
                    referralCard(
                        code: profile.referralCode,
                        needed: needed,
                        title: hasPlaced ? "Your rank is ready" : "Invite \(friends) to unlock Ranked",
                        subtitle: hasPlaced
                            ? "Placement complete. Invite \(friends) to reveal your rank and keep playing Ranked."
                            : (needed == 1
                                ? "Ranked opens once one friend signs up with your code."
                                : "Ranked opens once \(needed) friends sign up with your code.")
                    )
                } else {
                    rankedCard
                }

                // Quant-firm events teaser hidden for launch (Nov 2026); the
                // card itself is kept below so it can be re-enabled by
                // dropping it back in here.
                // eventsTeaserCard

                if let message = competition.errorMessage ?? store.errorMessage ?? ranked.errorMessage {
                    Text(message)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                SignOutButton(auth: auth)
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .task(id: revealKey) { await revealTierIfReady() }
    }

    /// Re-runs the reveal check whenever placement, the gate or the stored
    /// tier changes.
    private var revealKey: String {
        "\(competition.profile?.rankedMatches ?? -1)|\(competition.profile?.rankedTier ?? -1)|\(competition.referralCount)|\(remote.generation)"
    }

    /// Tier badge over the Elo: the band is the headline, the number sits
    /// under it with progress to the next division. Until placement is done
    /// (and the rank revealed) it reads "Unranked" with the reason beneath.
    private var eloCard: some View {
        let profile = competition.profile
        let standing = profile?.rankedTier.map { remote.tiers.standing(rating: profile?.elo ?? 1200, held: $0) }
        let total = remote.tiers.placementMatches
        let detail: String? = standing != nil ? nil
            : hasPlaced ? "Placement complete \u{2014} invite a friend to reveal your rank"
            : "Placement match \(min(total, (profile?.rankedMatches ?? 0) + 1)) of \(total)"
        return TierBadge(standing: standing, tiers: remote.tiers, caption: "YOUR RANK", unrankedDetail: detail)
    }

    private var paywallCard: some View {
        VStack(spacing: 14) {
            Text("Unlock Competition Mode")
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text("Get a global Elo rating, ranked matches against similarly-skilled players, and early access to quant-firm events.")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    if await store.purchase() {
                        await competition.recordPurchase(uid: uid)
                    }
                }
            } label: {
                ZStack {
                    if store.isPurchasing { ProgressView().tint(.white) }
                    Text(store.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock for $1.99")
                        .opacity(store.isPurchasing ? 0 : 1)
                }
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(store.isPurchasing)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    /// Share-your-code card used both by the (currently disabled) paywall's
    /// free-unlock path and by the per-player Ranked referral gate; only the
    /// copy and the number of dots differ.
    private func referralCard(code: String, needed: Int, title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)

            Text(subtitle)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ForEach(0..<max(needed, 1), id: \.self) { index in
                    Circle()
                        .fill(index < competition.referralCount ? Theme.accent : Theme.pill)
                        .frame(width: 14, height: 14)
                }
                Text("\(min(competition.referralCount, needed))/\(needed) referred")
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                // Referral counts are fetched on open, not live; a player who
                // just watched a friend sign up shouldn't have to relaunch.
                Button {
                    guard !isRefreshingReferrals else { return }
                    isRefreshingReferrals = true
                    Task {
                        await competition.refreshReferralStatus(uid: uid)
                        isRefreshingReferrals = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .rotationEffect(.degrees(isRefreshingReferrals ? 360 : 0))
                        .animation(isRefreshingReferrals ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshingReferrals)
                }
                .accessibilityLabel("Refresh referral count")
            }

            HStack(spacing: 10) {
                Text(code)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .kerning(4)
                    .foregroundStyle(Theme.inkDark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))

                ShareLink(item: "Play Krypto with me! Use my code \(code) when you sign up: \(AppLinks.store(ref: code))") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 14))
                }
            }

            if !competition.wasReferred {
                Divider()
                Text("Have a friend's code?")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 8) {
                    TextField("CODE", text: $referralInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(Theme.inkDark)
                        .tint(Theme.inkDark)
                        .padding()
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                    Button("Redeem") {
                        Task {
                            await competition.redeemReferralCode(referralInput, uid: uid)
                            referralInput = ""
                        }
                    }
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(referralInput.count < 4)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    private var rankedCard: some View {
        VStack(spacing: 14) {
            switch ranked.phase {
            case .idle, .error:
                Text("Ranked Play")
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text(hasPlaced
                     ? "Get matched with an opponent near your rating. First to solve wins Elo."
                     : "Play \(remote.tiers.placementMatches) placement matches to earn your rank. First to solve wins Elo.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                Button {
                    ranked.joinQueue(uid: uid, elo: competition.profile?.elo ?? 1200,
                                     heldTier: competition.profile?.rankedTier,
                                     matchesPlayed: competition.profile?.rankedMatches ?? 0,
                                     canRevealTier: hasMetReferralGate)
                } label: {
                    Label("Find Match", systemImage: "bolt.fill")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
            case .searching:
                // The searching popup (see `SearchingPopup`) covers the screen
                // while this is the phase; the card just holds its place.
                Text("Looking for a player\u{2026}")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            case .matched:
                Text("Match found!")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }


    private var unlockedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.accent)
            Text("Competition Mode unlocked")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.inkDark)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    private var eventsTeaserCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
            Text("Quant Firm Events")
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text("Future events from quant firms like Optiver, Jane Street, and more are coming to Competition Mode.")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Theme.pill.opacity(0.6)))
    }
}

#Preview {
    CompetitionView()
}

// MARK: - Searching popup

/// Full-screen "looking for a player" dialog shown while a ranked ticket is
/// waiting. Pulsing dots plus the rough ETA the service already estimates;
/// Cancel pulls the ticket. For a rematch the copy says so, since the
/// matcher will wait briefly for the same opponent before widening.
private struct SearchingPopup: View {
    @ObservedObject var ranked: RankedService
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 12, height: 12)
                            .scaleEffect(pulse ? 1.0 : 0.55)
                            .opacity(pulse ? 1.0 : 0.35)
                            .animation(
                                .easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(Double(index) * 0.18),
                                value: pulse
                            )
                    }
                }
                .padding(.top, 6)
                Text(ranked.isRematchSearch ? "Setting up a rematch\u{2026}" : "Looking for a player\u{2026}")
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text(ranked.isRematchSearch
                     ? "If your opponent has moved on, we'll find you someone else."
                     : "Matching you with someone near your rating.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                if let seconds = ranked.estimatedWaitSeconds {
                    Text("Estimated wait \(Self.formattedWait(seconds))")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.pill, in: Capsule())
                }
                Button { ranked.cancelQueue() } label: {
                    Text("Cancel")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(.horizontal, 32)
        }
        .onAppear { pulse = true }
    }

    private static func formattedWait(_ seconds: Int) -> String {
        if seconds < 60 { return "~\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "~\(minutes)m" : "~\(minutes)m \(remainder)s"
    }
}
