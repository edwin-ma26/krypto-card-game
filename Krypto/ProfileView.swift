import SwiftUI
import StoreKit
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import GoogleSignIn
import GameKit

struct ProfileView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var friends: FriendsService
    @Environment(\.dismiss) private var dismiss

    /// Debug-only: lets the hub (and Stats) render signed out when launched
    /// with `KRYPTO_DEMO_STATS=1`, for layout checks on a fresh simulator.
    private var showsDemoHub: Bool {
        #if DEBUG
        return DemoStats.isEnabled
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if auth.showsSignedInUI || showsDemoHub {
                    SignedInProfileView(auth: auth, friends: friends)
                } else {
                    SignedOutProfileView(auth: auth)
                }

                // A code redeemed during sign-up (in the nested email sheet)
                // lands here once that sheet is gone.
                ReferralThanksOverlay(auth: auth)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // Sign Out (and Delete Account) live on the pushed Account page.
        // Swapping the root alone leaves that page on top, so the player
        // would stay on the name editor; a new identity resets the stack
        // to the root, which is now the sign-in screen.
        .id(auth.showsSignedInUI)
        .chooseUsernamePrompt(auth: auth)
    }
}

// MARK: - Sign in

/// The one sign-up / log-in form, shared by Profile, Multiplayer, and
/// Competition Mode. Apple and Google up top, email/password below.
struct AuthSignInView: View {
    @ObservedObject var auth: AuthService
    var icon = "person.crop.circle.fill"
    var subtitle = "Sign in to add friends, send challenges, and track your stats."
    /// False when the host screen already drew its own icon and title above
    /// this form (Multiplayer does), so the two don't stack.
    var showsHeader = true
    /// Errors from the Apple / Google / Game Center buttons, shown right
    /// under them.
    @State private var providerError: String?
    @State private var isSubmitting = false
    @State private var showEmailFlow = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if showsHeader {
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 24)

                    Text("Sign in or create account")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Theme.inkDark)
                }

                Text(subtitle)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    // The icon carried the top inset; keep it when the icon is gone.
                    .padding(.top, showsHeader ? 0 : 24)

                providerButtons

                if let providerError {
                    Text(providerError)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                HStack(spacing: 12) {
                    Rectangle().fill(Theme.inkMuted.opacity(0.25)).frame(height: 1)
                    Text("or")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    Rectangle().fill(Theme.inkMuted.opacity(0.25)).frame(height: 1)
                }
                .padding(.horizontal, 24)

                // One line for the email route: the flow asks for the address
                // first and works out log-in vs sign-up itself (EmailSignInFlow).
                Button { showEmailFlow = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Continue with email")
                            .font(.system(size: 19, weight: .medium))
                    }
                    .foregroundStyle(Theme.inkDark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Theme.inkMuted.opacity(0.35), lineWidth: 1.5)
                    )
                }
                .disabled(isSubmitting)
                .padding(.horizontal, 24)

                legalDisclaimer
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showEmailFlow) {
            EmailSignInFlow(auth: auth)
                .presentationBackground(Theme.background)
        }
    }

    /// Apple up top (Apple's recommended placement for the quickest path),
    /// then Google and Game Center. Every button here both creates an account
    /// and signs an existing one in, so they all read "Continue with" — the
    /// wording Apple recommends for a combined sign-up / sign-in button — so a
    /// player without an account doesn't bounce off "Sign in".
    private var providerButtons: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.continue) { request in
                auth.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Button {
                Task { await handleGoogleSignIn() }
            } label: {
                HStack(spacing: 10) {
                    Image("GoogleLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("Continue with Google")
                        .font(.system(size: 19, weight: .medium))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black.opacity(0.15), lineWidth: 1))
            }
            .disabled(isSubmitting)

            Button {
                Task { await handleGameCenterSignIn() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Continue with Game Center")
                        .font(.system(size: 19, weight: .medium))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black.opacity(0.15), lineWidth: 1))
            }
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private var legalDisclaimer: some View {
        VStack(spacing: 4) {
            Text("By continuing, you agree to our")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 4) {
                Link("Terms of Use", destination: URL(string: "https://edwin-ma.notion.site/Terms-of-Use-3a7ecc2cff698012b6eafc281b53c0ba")!)
                Text("and")
                    .foregroundStyle(Theme.inkMuted)
                Link("Privacy Policy", destination: URL(string: "https://edwin-ma.notion.site/Privacy-Policy-3a7ecc2cff6980d2ad4ce62da787e7ae")!)
            }
            .font(.system(.caption2, design: .rounded, weight: .bold))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        providerError = nil
        switch result {
        case .success(let authorization):
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                try await auth.completeAppleSignIn(authorization)
            } catch {
                providerError = authErrorMessage(error)
            }
        case .failure(let error):
            // A user tapping "Cancel" on the Apple sheet isn't an error to surface.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            providerError = authErrorMessage(error)
        }
    }

    private func handleGoogleSignIn() async {
        providerError = nil
        guard let top = topViewController() else {
            providerError = "Couldn't open Google sign-in. Please try again."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await auth.signInWithGoogle(presenting: top)
        } catch {
            // Dismissing the Google sheet isn't an error to surface.
            if (error as NSError).domain == kGIDSignInErrorDomain,
               (error as NSError).code == GIDSignInError.canceled.rawValue { return }
            providerError = authErrorMessage(error)
        }
    }

    private func handleGameCenterSignIn() async {
        providerError = nil
        guard let top = topViewController() else {
            providerError = "Couldn't open Game Center sign-in. Please try again."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await auth.signInWithGameCenter(presenting: top)
        } catch {
            // Backing out of Apple's Game Center sheet isn't an error to surface.
            if (error as NSError).domain == GKErrorDomain,
               (error as NSError).code == GKError.cancelled.rawValue { return }
            providerError = authErrorMessage(error)
        }
    }
}

/// The view controller to present provider sign-in UI over: whatever is
/// topmost in the foreground scene (the sign-in form lives inside a sheet,
/// the Account page inside a navigation stack).
private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        .flatMap(\.windows)
    guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return nil }
    while let next = top.presentedViewController { top = next }
    return top
}

// MARK: - Signed out hub

/// The profile sheet for a signed-out player: just the sign-in options and
/// the legal / version footer. The destination rows only appear once
/// there's an account behind it.
private struct SignedOutProfileView: View {
    @ObservedObject var auth: AuthService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AuthSignInView(auth: auth)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                ProfileFooterLinks()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Sign out

/// The one "Sign Out" link, shared by the Account page and Competition Mode.
/// Signing out is easy to tap by accident and costs the player a trip back
/// through sign-in, so it confirms first — matching the Delete Account
/// button that sits right under it on the Account page.
struct SignOutButton: View {
    @ObservedObject var auth: AuthService
    @State private var showConfirmation = false

    var body: some View {
        Button("Sign Out") { showConfirmation = true }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
            .confirmationDialog(
                "Sign out of Krypto?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) { try? auth.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your rating, friends, and streak stay on your account. You'll need to sign in again to see them.")
            }
    }
}

// MARK: - Shared hub pieces

/// One row of the hub's destination list: icon, title, one-line summary,
/// and a chevron (or nothing, for a disabled "coming soon" row).
struct ProfileDestinationRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var showsDot = false
    var enabled = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text(subtitle)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if showsDot {
                Circle().fill(Theme.accent).frame(width: 10, height: 10)
            }
            if enabled {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.5)
    }
}

struct ProfileFooterLinks: View {
    @State private var showFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            Button { showFeedback = true } label: {
                HStack {
                    Text("Send Feedback")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkDark)
                    Spacer()
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showFeedback) { FeedbackSheet() }
            Divider().padding(.leading, 16)
            link(title: "Terms of Use", url: "https://edwin-ma.notion.site/Terms-of-Use-3a7ecc2cff698012b6eafc281b53c0ba")
            Divider().padding(.leading, 16)
            link(title: "Privacy Policy", url: "https://edwin-ma.notion.site/Privacy-Policy-3a7ecc2cff6980d2ad4ce62da787e7ae")
            Divider().padding(.leading, 16)
            HStack {
                Text("Version")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkDark)
                Spacer()
                Text(Self.versionString)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    private func link(title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkDark)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(16)
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

// MARK: - Signed in

private struct SignedInProfileView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var friends: FriendsService
    @StateObject private var store = StoreKitManager()

    @State private var displayName = ""
    @State private var isPremium = false
    @State private var addCodeInput = ""
    /// Seeded from the cached value so the badge draws at its known evolution
    /// immediately, then corrected by `Badges.sync` once the count comes back.
    @State private var badgeStage = Badges.stage

    @State private var editedName = ""
    @State private var accountMessage: String?
    @State private var isSavingName = false
    @State private var isSendingVerification = false
    @State private var verificationMessage: String?

    @State private var showDeleteConfirmation = false
    @State private var showDeletePasswordPrompt = false
    @State private var deleteAccountPassword = ""
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage: String?
    /// Neutral (non-error) note under Delete Account, e.g. "reset email sent".
    @State private var deleteNoteMessage: String?

    /// Rating / streak for the hub header, read straight off the profile doc.
    @State private var headerElo: Int?
    @State private var headerRankedTier: Int?
    @State private var headerStreak: Int?
    @StateObject private var remote = Remote.shared
    @AppStorage("soloRating") private var soloRating = SoloRating.initial
    @AppStorage("soloTier") private var soloTier = -1
    @AppStorage("soloPuzzlesCompleted") private var soloPuzzlesCompleted = 0
    @AppStorage(CardBoardSettings.dragToCombineKey) private var dragToCombine = false
    @State private var headerLongestStreak: Int?
    @AppStorage("gamesWon") private var soloGamesWon = 0
    @AppStorage("bestTime") private var soloBestTime = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                identityHeader
                destinationRows
                footerLinks
            }
            .padding(20)
        }
        .task(id: auth.user?.uid) {
            guard let uid = auth.user?.uid else { return }
            let data = try? await Firestore.firestore().collection("users").document(uid).getDocument().data()
            headerElo = data?["elo"] as? Int
            headerRankedTier = data?["rankedTier"] as? Int
            headerStreak = data?["dailyStreak"] as? Int
            headerLongestStreak = data?["dailyLongestStreak"] as? Int
        }
        .task(id: auth.user?.uid) {
            guard let uid = auth.user?.uid else { return }
            friends.start(uid: uid)
            // Show cached data immediately so re-opening the profile sheet
            // doesn't look like it's reloading from scratch every time.
            applyCachedAccountInfo()
            // Publish a badge earned while signed out (or on another device)
            // before loading friends, so a fresh sign-in shows it to others
            // from the first profile open rather than the second.
            badgeStage = await Badges.sync(uid: uid)
            async let friendsLoad: () = friends.loadFriends(uid: uid)
            async let accountLoad: () = loadAccountInfo(uid: uid)
            async let verifyLoad: () = auth.refreshEmailVerificationStatus()
            _ = await (friendsLoad, accountLoad, verifyLoad)
        }
        .onChange(of: auth.cachedDisplayName) { _, newValue in
            // Sign-up seeds the cached display name asynchronously once the
            // Firebase auth/Firestore race resolves, which can happen after
            // this screen has already copied an empty name into local state.
            // Re-sync when it lands, but don't stomp on an in-progress edit.
            if editedName == displayName { editedName = newValue }
            displayName = newValue
        }
    }

    // MARK: - Hub

    private var identityHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.pill)
                    .frame(width: 84, height: 84)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 6) {
                Text(displayName.isEmpty ? "Player" : displayName)
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                if Badges.hasFoundingPup {
                    BadgeMark(size: 24, stage: badgeStage, showsNextHint: true)
                }
            }
            if !accountSubtitle.isEmpty {
                Text(accountSubtitle)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            // Two ratings now, so each chip names its mode; the tier is the
            // value and the number rides along as the label.
            let solo = soloPuzzlesCompleted >= remote.tiers.unrankedUntil
                ? remote.tiers.standing(rating: soloRating, held: soloTier >= 0 ? soloTier : nil) : nil
            // Ranked is badged only once placed (a held tier is stored).
            let ranked = headerRankedTier.flatMap { held in headerElo.map { remote.tiers.standing(rating: $0, held: held) } }
            HStack(spacing: 10) {
                statChip(icon: "seal.fill", value: solo?.label ?? "Unranked",
                         label: solo.map { "solo · \(String($0.rating))" } ?? "solo", tint: solo?.color)
                statChip(icon: "seal.fill", value: ranked?.label ?? (headerElo != nil ? "Unranked" : "—"),
                         label: ranked.map { "ranked · \(String($0.rating))" } ?? "ranked", tint: ranked?.color)
            }
            .padding(.top, 2)
            statChip(icon: "flame.fill", value: headerStreak.map(String.init) ?? "—", label: "day streak")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func statChip(icon: String, value: String, label: String, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint ?? Theme.accent)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
                .monospacedDigit()
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white, in: Capsule())
    }

    private var friendsSummary: String {
        let count = friends.friends.count
        let requests = friends.incomingFriendRequests.count
        let base = count == 1 ? "1 friend" : "\(count) friends"
        return requests > 0 ? "\(base) · \(requests) request\(requests == 1 ? "" : "s")" : base
    }

    private var statsSummary: String {
        guard soloGamesWon > 0 else { return "Times, ratings, streaks" }
        let solved = soloGamesWon == 1 ? "1 solved" : "\(soloGamesWon) solved"
        guard soloBestTime > 0 else { return solved }
        return "\(solved) · best \(String(format: "%d:%02d", soloBestTime / 60, soloBestTime % 60))"
    }

    /// The hub destinations as one grouped list, styled like the footer card
    /// below it. Dividers start after the icon column.
    private var destinationRows: some View {
        VStack(spacing: 0) {
            NavigationLink { accountPage } label: {
                destinationRow(icon: "person.fill", title: "Account", subtitle: accountSubtitle.isEmpty ? "Name, email, sign out" : accountSubtitle)
            }
            .buttonStyle(.plain)
            rowDivider
            NavigationLink { friendsPage } label: {
                destinationRow(
                    icon: "person.2.fill", title: "Friends", subtitle: friendsSummary,
                    showsDot: !friends.incomingFriendRequests.isEmpty
                )
            }
            .buttonStyle(.plain)
            rowDivider
            NavigationLink {
                StatsPage(elo: headerElo, rankedTier: headerRankedTier, streak: headerStreak, longestStreak: headerLongestStreak)
            } label: {
                destinationRow(icon: "chart.xyaxis.line", title: "Stats", subtitle: statsSummary)
            }
            .buttonStyle(.plain)
            rowDivider
            // Themes are not built yet. Card facing used to live here, but it
            // follows the mode now (two-way only in same-phone Multiplayer).
            destinationRow(icon: "paintpalette.fill", title: "Appearance", subtitle: "Coming soon", enabled: false)
            rowDivider
            dragToCombineRow
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    /// Inset past the 16pt padding, 40pt icon, and 14pt gap of the row.
    private var rowDivider: some View { Divider().padding(.leading, 70) }

    /// Experimental input: swipe a card toward an operator, release on another.
    private var dragToCombineRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Swipe to Combine")
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text("Swipe a card ↖ +  ↗ −  ↙ ×  ↘ ÷, then drop it on another")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $dragToCombine)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func destinationRow(icon: String, title: String, subtitle: String, showsDot: Bool = false, enabled: Bool = true) -> some View {
        ProfileDestinationRow(icon: icon, title: title, subtitle: subtitle, showsDot: showsDot, enabled: enabled)
    }

    private var footerLinks: some View { ProfileFooterLinks() }

    // MARK: - Pages

    private var accountPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                accountCard
                if competitionPaywallEnabled {
                    subscriptionCard
                }

                SignOutButton(auth: auth)
                    .padding(.top, 4)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    ZStack {
                        if isDeletingAccount { ProgressView().tint(.red.opacity(0.75)) }
                        Text("Delete Account").opacity(isDeletingAccount ? 0 : 1)
                    }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.75))
                }
                .disabled(isDeletingAccount)
                .confirmationDialog(
                    "Delete your account?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Account", role: .destructive) {
                        // Only password accounts have a password to confirm;
                        // Apple / Google / Game Center accounts re-run their
                        // provider's sheet instead (Firebase requires a recent
                        // sign-in either way).
                        // Let the confirmation dialog finish dismissing
                        // before the next presentation (an alert, or a
                        // provider sheet); presenting while it's still
                        // animating out gets dropped or lands a beat late.
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            if auth.reauthMethod == .password {
                                showDeletePasswordPrompt = true
                            } else {
                                await deleteAccountWithProvider()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes your profile, friends, and Competition Mode progress. This can't be undone.")
                }
                .alert("Confirm your password", isPresented: $showDeletePasswordPrompt) {
                    SecureField("Current password", text: $deleteAccountPassword)
                    Button("Delete Account", role: .destructive) {
                        Task { await deleteAccount() }
                    }
                    .disabled(deleteAccountPassword.isEmpty)
                    Button("Forgot password? Email me a reset link") {
                        deleteAccountPassword = ""
                        Task { await sendDeleteResetEmail() }
                    }
                    Button("Cancel", role: .cancel) { deleteAccountPassword = "" }
                } message: {
                    Text("For your security, your current password is required to permanently delete your account.")
                }

                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                if let deleteNoteMessage {
                    Text(deleteNoteMessage)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var friendsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                friendsCard
                if let message = friends.errorMessage {
                    Text(message)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Password account: confirm the typed password, then delete.
    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        deleteErrorMessage = nil
        deleteNoteMessage = nil
        do {
            try await auth.reauthenticate(currentPassword: deleteAccountPassword)
            deleteAccountPassword = ""
            try await deleteAccountData()
        } catch {
            deleteAccountPassword = ""
            deleteErrorMessage = "Couldn't delete your account: \(authErrorMessage(error))"
        }
    }

    /// Apple / Google / Game Center account. Firebase only insists on a
    /// re-authentication when the session isn't recent, so Google and Game
    /// Center try the delete first (instant for someone who just signed in)
    /// and only run the provider's sheet if Firebase asks for it. Apple
    /// always runs its sheet first: the authorization code it returns is
    /// what lets us revoke the Sign in with Apple token, which App Store
    /// review requires on deletion. Backing out of a sheet cancels quietly.
    private func deleteAccountWithProvider() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        deleteErrorMessage = nil
        deleteNoteMessage = nil
        do {
            if auth.reauthMethod == .apple {
                try await reauthenticateThenDelete()
            } else {
                try await deleteAccountData()
            }
        } catch let error as NSError where AuthErrorCode(rawValue: error.code) == .requiresRecentLogin {
            do {
                try await reauthenticateThenDelete()
            } catch {
                if AuthService.isUserCancellation(error) { return }
                deleteErrorMessage = "Couldn't delete your account: \(authErrorMessage(error))"
            }
        } catch {
            if AuthService.isUserCancellation(error) { return }
            deleteErrorMessage = "Couldn't delete your account: \(authErrorMessage(error))"
        }
    }

    private func reauthenticateThenDelete() async throws {
        guard let top = topViewController() else {
            throw NSError(domain: usernameErrorDomain, code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open sign-in to confirm it's you. Please try again.",
            ])
        }
        try await auth.reauthenticateWithProvider(presenting: top)
        try await deleteAccountData()
    }

    /// The signed-in player forgot their password: send a reset link to the
    /// account's email so they can set a new one and come back.
    private func sendDeleteResetEmail() async {
        deleteErrorMessage = nil
        do {
            let email = try await auth.sendPasswordResetToCurrentUser()
            deleteNoteMessage = "Reset link sent to \(email). Set a new password from that email, then come back here to delete your account. \(authSpamNote)"
        } catch {
            deleteErrorMessage = "Couldn't send reset email: \(authErrorMessage(error))"
        }
    }

    /// Deletes the Auth account. The caller must have re-authenticated first.
    /// Everything the account owned in Firestore (profile and its solves
    /// history, username and referral-code reservations, friend links,
    /// challenges, queue ticket) is removed server-side by the
    /// `onUserDeleted` Cloud Function, which also covers an app killed
    /// mid-delete and accounts removed from the Firebase console.
    private func deleteAccountData() async throws {
        try await auth.deleteAccount()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ACCOUNT")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName.isEmpty ? "Player" : displayName)
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                        // Reads from the local flag rather than the profile doc:
                        // this is your own badge, and it's earned on-device
                        // before there's necessarily an account to sync it to.
                        if Badges.hasFoundingPup {
                            BadgeMark(size: 22, stage: badgeStage, showsNextHint: true)
                        }
                    }
                    Text(accountSubtitle)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer()
            }

            if auth.hasPasswordProvider && !auth.isEmailVerified {
                emailVerificationBanner
            }

            Divider()

            editableField(
                label: "Display name",
                text: $editedName,
                isSaving: isSavingName,
                canSave: !editedName.isEmpty && editedName != displayName
            ) { await saveDisplayName() }

            // Email/password management only applies to password accounts;
            // Apple, Google, and Game Center manage theirs on the provider side.
            if auth.hasPasswordProvider {
                NavigationLink {
                    ChangeEmailView(auth: auth, currentEmail: auth.user?.email ?? "")
                } label: {
                    accountNavRow(title: "Email", value: auth.user?.email ?? "")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ChangePasswordView(auth: auth)
                } label: {
                    accountNavRow(title: "Password", value: "••••••••")
                }
                .buttonStyle(.plain)
            }

            if let accountMessage {
                Text(accountMessage)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    /// Email when there is one, otherwise which provider the account uses
    /// (Game Center accounts carry no email at all).
    private var accountSubtitle: String {
        if let email = auth.user?.email, !email.isEmpty { return email }
        if let method = auth.signInMethodLabel { return "Signed in with \(method)" }
        return ""
    }

    private var emailVerificationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Please verify your email")
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
            }
            Text(authSpamNote)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 12) {
                Button {
                    Task { await resendVerification() }
                } label: {
                    if isSendingVerification {
                        ProgressView().tint(Theme.inkMuted)
                    } else {
                        Text("Resend email")
                    }
                }
                .disabled(isSendingVerification)

                Button("I've verified") {
                    Task { await auth.refreshEmailVerificationStatus() }
                }
            }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.accent)

            if let verificationMessage {
                Text(verificationMessage)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func resendVerification() async {
        isSendingVerification = true
        defer { isSendingVerification = false }
        do {
            try await auth.sendEmailVerification()
            verificationMessage = "Verification email sent."
        } catch {
            verificationMessage = "Couldn't send email: \(authErrorMessage(error))"
        }
    }

    private func accountNavRow(title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                Text(value)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkDark)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding()
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
    }

    private func editableField(
        label: String,
        text: Binding<String>,
        isSaving: Bool,
        canSave: Bool,
        keyboardType: UIKeyboardType = .default,
        isSecure: Bool = false,
        save: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 8) {
                Group {
                    if isSecure {
                        SecureField(label, text: text)
                    } else {
                        TextField(label, text: text)
                            .keyboardType(keyboardType)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.inkDark)
                .tint(Theme.inkDark)
                .padding()
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))

                Button {
                    Task { await save() }
                } label: {
                    ZStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Save").opacity(isSaving ? 0 : 1)
                    }
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(canSave ? Theme.button : Theme.button.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canSave || isSaving)
            }
        }
    }

    private func saveDisplayName() async {
        guard auth.user?.uid != nil else { return }
        isSavingName = true
        defer { isSavingName = false }
        do {
            try await auth.changeUsername(to: editedName)
            displayName = auth.cachedDisplayName
            editedName = auth.cachedDisplayName
            accountMessage = "Display name updated."
        } catch {
            accountMessage = authErrorMessage(error)
        }
    }

    /// The message shared by the "Invite Friends" button — includes the user's
    /// username so invitees can add them back, plus the download link.
    private var inviteMessage: String {
        let handle = auth.cachedDisplayName.trimmingCharacters(in: .whitespaces)
        let who = handle.isEmpty ? "" : " My username is \(handle)."
        let code = auth.cachedFriendCode.trimmingCharacters(in: .whitespaces)
        // State the code in the text, not just inside the link. App Store URLs
        // drop query parameters, so the `?ref=` on the end never reaches the
        // installed app — the recipient typing this code at sign-up is the only
        // thing that actually credits the referral.
        let invite = code.isEmpty ? "" : " Use my code \(code) when you sign up."
        return "Play Krypto with me!\(who)\(invite) Download and add me as a friend: \(AppLinks.store(ref: code))"
    }

    private var friendsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FRIENDS")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if addCodeInput.isEmpty {
                        Text("FRIEND'S USERNAME")
                            .foregroundStyle(Theme.codeText.opacity(0.6))
                    }
                    TextField("", text: $addCodeInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(Theme.codeText)
                        .tint(Theme.codeText)
                }
                .padding()
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                Button("Add") {
                    guard let uid = auth.user?.uid else { return }
                    Task {
                        await friends.sendFriendRequest(username: addCodeInput, myUid: uid, myName: displayName)
                        addCodeInput = ""
                    }
                }
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 50)
                .background(Theme.button, in: RoundedRectangle(cornerRadius: 14))
                .disabled(addCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ShareLink(item: inviteMessage) {
                Label("Invite Friends", systemImage: "square.and.arrow.up")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
            }

            if !friends.incomingFriendRequests.isEmpty {
                Text("REQUESTS")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Theme.inkMuted)
                LazyVStack(spacing: 8) {
                    ForEach(friends.incomingFriendRequests) { request in
                        HStack {
                            Text(request.fromName)
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                            if request.hasFoundingPup {
                                BadgeMark(size: 22, stage: request.badgeStage)
                            }
                            Spacer()
                            Button {
                                guard let uid = auth.user?.uid else { return }
                                Task { await friends.acceptFriendRequest(request, myUid: uid) }
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(10)
                                    .background(Theme.codeField, in: Circle())
                            }
                            Button {
                                guard let uid = auth.user?.uid else { return }
                                friends.declineFriendRequest(request, myUid: uid)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.red.opacity(0.7))
                                    .padding(10)
                                    .background(Theme.codeField, in: Circle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.codeField, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

            if friends.isLoading {
                ProgressView().tint(Theme.inkMuted).frame(maxWidth: .infinity)
            } else if friends.friends.isEmpty {
                Text("No friends yet — share your code above to add one.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                // Lazy so long friends lists only build the rows on screen.
                LazyVStack(spacing: 8) {
                    ForEach(friends.friends) { friend in
                        HStack {
                            Text(friend.displayName)
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                            if friend.hasFoundingPup {
                                BadgeMark(size: 22, stage: friend.badgeStage)
                            }
                            Spacer()
                            Button {
                                guard let uid = auth.user?.uid else { return }
                                Task { await friends.removeFriend(friend.id, myUid: uid) }
                            } label: {
                                Image(systemName: "person.fill.xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.red.opacity(0.7))
                                    .padding(10)
                                    .background(Theme.codeField, in: Circle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.codeField, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SUBSCRIPTION")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)

            if isPremium {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Competition Mode unlocked")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                }

                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    Text("Manage or Cancel Subscription")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                Text("You haven't unlocked Competition Mode yet.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                Button {
                    Task {
                        if await store.purchase(), let uid = auth.user?.uid {
                            try? await Firestore.firestore().collection("users").document(uid).updateData([
                                "isPremium": true,
                                "premiumSource": "purchase",
                            ])
                            isPremium = true
                            auth.updateCachedIsPremium(true)
                        }
                    }
                } label: {
                    ZStack {
                        if store.isPurchasing { ProgressView().tint(.white) }
                        Text(store.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock Competition Mode")
                            .opacity(store.isPurchasing ? 0 : 1)
                    }
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(store.isPurchasing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white).shadow(color: .black.opacity(0.06), radius: 10, y: 4))
    }

    /// Seeds the visible fields from AuthService's cache, if any, so the
    /// screen never shows a blank/loading state on repeat opens.
    private func applyCachedAccountInfo() {
        guard auth.hasCachedProfile else { return }
        displayName = auth.cachedDisplayName
        isPremium = auth.cachedIsPremium
        editedName = auth.cachedDisplayName
    }

    private func loadAccountInfo(uid: String) async {
        await auth.loadProfile(uid: uid)
        displayName = auth.cachedDisplayName
        isPremium = auth.cachedIsPremium
        editedName = auth.cachedDisplayName
    }
}

// MARK: - Change email / password

private struct ChangeEmailView: View {
    @ObservedObject var auth: AuthService
    let currentEmail: String
    @State private var newEmail = ""
    @State private var currentPassword = ""
    @State private var isSaving = false
    @State private var message: String?

    private var canSave: Bool {
        !newEmail.isEmpty && newEmail != currentEmail && !currentPassword.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                changeField(label: "New email", text: $newEmail, keyboardType: .emailAddress)
                changeField(label: "Current password", text: $currentPassword, isSecure: true)

                Text("For your security, confirm your current password to change your email.")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                ForgotPasswordLink(auth: auth, message: $message)

                Button {
                    Task { await save() }
                } label: {
                    ZStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Save").opacity(isSaving ? 0 : 1)
                    }
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canSave ? Theme.button : Theme.button.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!canSave || isSaving)

                if let message {
                    Text(message)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(20)
        }
        .navigationTitle("Change Email")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateEmail(newEmail, currentPassword: currentPassword)
            currentPassword = ""
            message = "Check \(newEmail) and tap the link to confirm your new email. \(authSpamNote)"
        } catch {
            message = "Couldn't update email: \(authErrorMessage(error))"
        }
    }
}

private struct ChangePasswordView: View {
    @ObservedObject var auth: AuthService
    @State private var newPassword = ""
    @State private var currentPassword = ""
    @State private var isSaving = false
    @State private var message: String?

    private var canSave: Bool {
        newPassword.count >= 6 && !currentPassword.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                changeField(label: "New password", text: $newPassword, isSecure: true)

                // Explain why Save stays disabled instead of leaving the
                // greyed-out button unexplained once they've started typing.
                if !newPassword.isEmpty && newPassword.count < 6 {
                    Text("Password must be at least 6 characters.")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.85))
                }

                changeField(label: "Current password", text: $currentPassword, isSecure: true)

                Text("For your security, confirm your current password to change your password.")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                ForgotPasswordLink(auth: auth, message: $message)

                Button {
                    Task { await save() }
                } label: {
                    ZStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Save").opacity(isSaving ? 0 : 1)
                    }
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canSave ? Theme.button : Theme.button.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!canSave || isSaving)

                if let message {
                    Text(message)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(20)
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updatePassword(newPassword, currentPassword: currentPassword)
            newPassword = ""
            currentPassword = ""
            message = "Password updated."
        } catch {
            message = "Couldn't update password: \(authErrorMessage(error))"
        }
    }
}

/// "Forgot your password?" for a signed-in player on a screen that asks for
/// the current password. Emails a reset link to the account's own address and
/// reports the result through the host screen's `message`.
private struct ForgotPasswordLink: View {
    @ObservedObject var auth: AuthService
    @Binding var message: String?
    @State private var isSending = false

    var body: some View {
        Button {
            Task { await send() }
        } label: {
            HStack(spacing: 6) {
                if isSending { ProgressView().tint(Theme.inkMuted).controlSize(.small) }
                Text("Forgot your password? Email me a reset link")
            }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .disabled(isSending)
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            let email = try await auth.sendPasswordResetToCurrentUser()
            message = "Reset link sent to \(email). Set a new password from that email, then come back here. \(authSpamNote)"
        } catch {
            message = "Couldn't send reset email: \(authErrorMessage(error))"
        }
    }
}

// `@MainActor` because `Theme` now reads the remote-config palette snapshot,
// which is main-actor isolated; this is a free function, so unlike the view
// types that call it, it isn't implicitly isolated already.
@MainActor
private func changeField(label: String, text: Binding<String>, keyboardType: UIKeyboardType = .default, isSecure: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label)
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
        Group {
            if isSecure {
                SecureField(label, text: text)
            } else {
                TextField(label, text: text)
                    .keyboardType(keyboardType)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .foregroundStyle(Theme.inkDark)
        .tint(Theme.inkDark)
        .padding()
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ProfileView(auth: AuthService(), friends: FriendsService())
}
