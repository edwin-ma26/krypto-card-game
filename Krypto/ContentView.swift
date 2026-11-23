import SwiftUI
import UIKit
import UserNotifications
import FirebaseMessaging

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    // Deals in `onAppear` rather than at init so an unfinished rated puzzle
    // can be restored instead of dealt over (see `GameViewModel.resumeSavedSoloGame`).
    @StateObject private var game = GameViewModel(dealsOwnPuzzle: false)
    @StateObject private var multiplayer: MultiplayerService
    @StateObject private var auth = AuthService()
    @StateObject private var friends = FriendsService()
    @StateObject private var soloRating = SoloRatingService()
    /// Observed (not just read) so a console kill-switch takes effect on the
    /// next fetch rather than only on the next cold launch.
    @StateObject private var remote = Remote.shared
    @State private var showStats = false
    @State private var showMultiplayer = false
    @State private var showProfile = false
    @State private var showNewGameConfirm = false
    @State private var showGiveUpConfirm = false
    @State private var hasStartedBoard = false
    /// The result card was closed with its X, so the finished board shows
    /// underneath (to look over the solve, or leave via the back chevron).
    @State private var resultDismissed = false

    /// Set when Home launches straight into the Multiplayer flow, so the
    /// create/join sheet is already open instead of requiring an extra tap.
    var startInMultiplayerMenu = false

    /// A challenge room code to join on appear. Set when the player accepts a
    /// challenge from the Home screen, which has no `MultiplayerService` of its
    /// own to join the room with.
    var joinRoomOnLaunch: String? = nil

    /// `MultiplayerHubView` opens the board with its own service once a match
    /// has started, so the shared deal is (or is about to be) already there.
    private let startsInMatch: Bool

    /// - Parameter multiplayer: a service whose match is already underway.
    ///   Without one the board makes its own, as solo play and the
    ///   challenge-accept path do.
    init(startInMultiplayerMenu: Bool = false, joinRoomOnLaunch: String? = nil, multiplayer: MultiplayerService? = nil) {
        self.startInMultiplayerMenu = startInMultiplayerMenu
        self.joinRoomOnLaunch = joinRoomOnLaunch
        self.startsInMatch = multiplayer != nil
        _multiplayer = StateObject(wrappedValue: multiplayer ?? MultiplayerService())
    }

    /// Home opened this screen for multiplayer (menu, invite, or a started
    /// match). The board is then never a rated solo puzzle, and leaving
    /// multiplayer goes back to where it came from rather than dropping the
    /// player onto a solo board with a ticking clock.
    private var launchedForMultiplayer: Bool {
        startInMultiplayerMenu || joinRoomOnLaunch != nil || startsInMatch
    }

    /// True when the app isn't active or any sheet/overlay is covering the
    /// board, so the solve clock should be paused.
    private var isBoardObstructed: Bool {
        scenePhase != .active
            || showStats || showMultiplayer || showProfile || showNewGameConfirm || showGiveUpConfirm
    }

    /// Signed-out players get a handful of rated puzzles, then the result
    /// card's button asks them to sign in before dealing another.
    private var needsSignInToContinue: Bool {
        soloRating.needsSignIn(isSignedIn: auth.isSignedIn)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // The puzzle's fixed-height chrome (cards, target, operation/bottom
            // rows) can exceed the screen on shorter devices — especially during
            // a challenge, when the player list adds another block. A plain
            // centered VStack overflows *symmetrically* when that happens,
            // pushing the top bar up under the Dynamic Island. Hosting it in a
            // ScrollView whose content is at least as tall as the safe area keeps
            // the centered look whenever it fits, and simply scrolls (never
            // bleeding into the island) when it doesn't.
            puzzleScroll

            if multiplayer.isActive, let won = multiplayer.winnerIsMe {
                raceResultOverlay(won: won)
            } else if multiplayer.opponentHoldsLock {
                opponentSolvingOverlay
            } else if game.isSolved {
                if multiplayer.isActive {
                    waitingForOpponentOverlay
                } else if !resultDismissed {
                    winOverlay
                }
            }

            if showNewGameConfirm {
                newGameConfirmOverlay
            }
            if showGiveUpConfirm {
                giveUpConfirmOverlay
            }
        }
        .animation(.spring(duration: 0.35), value: game.cards)
        .animation(.easeInOut(duration: 0.2), value: game.hint)
        .animation(.easeInOut(duration: 0.2), value: multiplayer.sharedHint)
        .animation(.easeInOut(duration: 0.25), value: game.isSolved)
        .animation(.easeInOut(duration: 0.25), value: multiplayer.winnerIsMe)
        .animation(.easeInOut(duration: 0.25), value: multiplayer.lockHolder)
        .animation(.easeInOut(duration: 0.25), value: friends.incomingChallenge != nil)
        .animation(.easeInOut(duration: 0.25), value: friends.incomingFriendRequests)
        .animation(.easeInOut(duration: 0.25), value: friends.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: showNewGameConfirm)
        .animation(.easeInOut(duration: 0.2), value: showGiveUpConfirm)
        .animation(.easeInOut(duration: 0.25), value: game.gaveUp)
        .animation(.easeInOut(duration: 0.25), value: resultDismissed)
        .onChange(of: game.isOver) { _, over in
            if !over { resultDismissed = false }
        }
        .sheet(isPresented: $showStats) { statsSheet }
        .sheet(isPresented: $showMultiplayer) {
            MultiplayerView(service: multiplayer, auth: auth, friends: friends)
        }
        .sheet(isPresented: $showProfile) { ProfileView(auth: auth, friends: friends) }
        .onAppear {
            if !hasStartedBoard {
                hasStartedBoard = true
                game.soloRating = soloRating
                if launchedForMultiplayer {
                    // Marking the game as multiplayer keeps it out of the
                    // rating and off the solo-progress save. A match that has
                    // already dealt starts on that hand; otherwise this is
                    // unrated filler the shared deal replaces when it lands.
                    game.multiplayer = multiplayer
                    if startsInMatch, multiplayer.phase == .playing, let puzzle = multiplayer.puzzle {
                        game.startShared(hand: puzzle.hand, target: puzzle.target)
                    } else {
                        let (hand, target) = Krypto.deal()
                        game.startShared(hand: hand, target: target)
                    }
                } else if !game.resumeSavedSoloGame() {
                    game.newGame()
                }
            }
            if startInMultiplayerMenu { showMultiplayer = true }
            if let code = joinRoomOnLaunch {
                // An invite link opened by someone without an account lands
                // them on the sign-in form instead of a half-joined room.
                if auth.isSignedIn {
                    Task { await multiplayer.joinRoom(code) }
                } else {
                    showMultiplayer = true
                }
            }
        }
        .onChange(of: multiplayer.puzzle) { _, puzzle in
            guard let puzzle, multiplayer.phase == .playing else { return }
            game.multiplayer = multiplayer
            game.startShared(hand: puzzle.hand, target: puzzle.target)
        }
        .onChange(of: multiplayer.phase) { _, phase in
            // When a match ends by the room closing (the opponent tapped Exit,
            // or a disconnect tore the room down), this player is dropped back to
            // idle with the old multiplayer board still on screen. Deal them a
            // fresh solo game. The player who left explicitly does this themselves
            // and has already cleared `game.multiplayer`, so this won't double-fire.
            guard phase == .idle, game.multiplayer != nil else { return }
            game.multiplayer = nil
            if launchedForMultiplayer { dismiss() } else { game.newGame() }
        }
        .onChange(of: showMultiplayer) { _, shown in
            // Swiping the create/join sheet away without a room: there's
            // nothing to play here, so go back to Home.
            if !shown, launchedForMultiplayer, !multiplayer.isActive { dismiss() }
        }
        .onChange(of: multiplayer.iHoldLock) { _, _ in
            // Each buzz is a fresh attempt from the dealt hand — reset the board
            // whenever the lock changes hands (but not once a winner is decided,
            // so the solved board stays put under the result popup).
            guard multiplayer.isRacing, multiplayer.winnerIsMe == nil,
                  let puzzle = multiplayer.puzzle else { return }
            game.startShared(hand: puzzle.hand, target: puzzle.target)
        }
        // Only the profile sheet used to load the cached username, so a board
        // opened straight from Home introduced this player to opponents as
        // "Player". Load it here too; the task below re-runs once it lands.
        .task(id: auth.user?.uid) {
            if let uid = auth.user?.uid { await auth.loadProfile(uid: uid) }
        }
        .task(id: auth.cachedDisplayName) {
            // Never downgrade a real name (set by the picker that created or
            // joined the room) to the placeholder while the cache is loading.
            if multiplayer.myName.isEmpty || localPlayerName != "Player" {
                multiplayer.myName = localPlayerName
            }
        }
        .task(id: auth.user?.uid) {
            // Anonymous sessions keep the device-local rating; only a real
            // account mirrors it to the profile.
            await soloRating.bind(uid: auth.isSignedIn ? auth.user?.uid : nil)
        }
        // Backing out to Home mid-puzzle parks it (resumes next visit); only
        // a process death with the board on screen counts as an abandon.
        .onDisappear { game.park() }
        .task(id: game.abandonedNotice) {
            guard game.abandonedNotice != nil else { return }
            // A cancelled sleep (the task restarting) must not clear the
            // notice early, hence no `try?` here.
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            game.abandonedNotice = nil
        }
        .overlay(alignment: .top) {
            if let cost = game.abandonedNotice {
                Label("Last puzzle counted as a loss (\u{2212}\(String(cost)))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.85), in: Capsule())
                    // Just under the top bar, over the TARGET caption; the
                    // board itself stays clear.
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: game.abandonedNotice)
        .onChange(of: auth.user?.uid) { _, uid in
            if let uid {
                friends.start(uid: uid)
                Task { await friends.loadFriends(uid: uid) }
                Task { await registerForPushNotifications() }
                // Recompute the badge's evolution here, not just on the profile
                // screen. A referral is earned by someone else's action, so the
                // owner gets no signal it happened — without this the dog only
                // mutates if they happen to open Profile, which looks broken.
                Task { await Badges.sync(uid: uid) }
            } else {
                friends.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fcmTokenRefreshed)) { note in
            guard let token = note.object as? String else { return }
            auth.saveFCMToken(token)
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground: Firestore's live stream was torn down
            // while suspended, so force the room to re-sync — otherwise an
            // in-progress race would sit on stale state. The solve clock is
            // handled by pause/resume below.
            guard phase == .active else { return }
            multiplayer.reconnect()
            // Catches referrals that landed while the app sat in the
            // background, which is when most of them will arrive.
            if let uid = auth.user?.uid {
                Task { await Badges.sync(uid: uid) }
            }
        }
        // Pause the solve clock whenever the board is obstructed — the app is
        // backgrounded, or a sheet/overlay (stats, multiplayer, profile,
        // new-game confirm) is covering it — and resume when it clears.
        .onChange(of: isBoardObstructed) { _, obstructed in
            if obstructed { game.pause() } else { game.resume() }
        }
        .overlay(alignment: .top) {
            IncomingAlertsView(
                friends: friends,
                suppressChallenge: multiplayer.isRacing,
                onAcceptChallenge: { challenge in
                    let code = challenge.roomCode
                    friends.clearIncomingChallenge()
                    // A challenge can arrive while hosting a room of your own
                    // (waiting for someone to join) — leave it first so it
                    // doesn't sit around orphaned in Firestore.
                    if multiplayer.isActive { multiplayer.leave() }
                    guard auth.isSignedIn else { showMultiplayer = true; return }
                    Task { await multiplayer.joinRoom(code) }
                },
                onOpenFriendRequests: { showProfile = true },
                onAcceptRankedRematch: {
                    // Hand off to Competition: leave any casual room, close
                    // this screen, and let Home present Competition.
                    if multiplayer.isActive { multiplayer.leave() }
                    game.multiplayer = nil
                    RankedService.shared.wantsCompetitionScreen = true
                    dismiss()
                }
            )
        }
    }

    /// Name shown to multiplayer opponents. Delegates to `AuthService` so every
    /// call site (this task, room creation, challenges) resolves it identically.
    private var localPlayerName: String { auth.multiplayerName }

    // MARK: - Push notifications

    /// Prompts for permission (a no-op if already asked) and, once granted,
    /// registers for APNs and saves the resulting FCM token so the friend
    /// request/accept Cloud Functions can reach this device.
    private func registerForPushNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let token = try? await Messaging.messaging().token() {
            auth.saveFCMToken(token)
        }
    }


    /// The scrolling puzzle area. Extracted from `body` (along with `puzzleColumn`)
    /// so the type-checker stays within budget once the width/height frame is applied.
    private var puzzleScroll: some View {
        GeometryReader { geo in
            // Cap the playfield to a phone-sized, centered column so it doesn't
            // stretch across a large iPad screen — on iPhone the width mininum is a
            // no-op and it just fills the screen as before.
            // Use the full width and height (minus the fixed chrome) so the board
            // fills the screen on iPad the same way it does on a phone, instead of
            // sitting in a small centered block with big empty margins.
            let boardWidth = geo.size.width
            // Size the cards to the space left after the fixed chrome, so the whole
            // board fits without scrolling on any device — even in a race, where the
            // player list and "Krypto!" bar eat extra height. `reserved` approximates
            // everything but the three card rows; the generous cap only bites on very
            // large canvases (e.g. a Mac window), and the ScrollView is a safety net
            // for very large Dynamic Type.
            let reserved: CGFloat = multiplayer.phase == .playing ? 550 : 405
            // The hand is two rows (3 over 2) in the space the old three-row
            // grid had; CardBoard also caps the height so narrow cards don't
            // go tall and thin on big screens.
            let threeRows = 3 * min(300, max(66, (geo.size.height - reserved) / 3))
            let cardHeight = CardBoard<EmptyView>.cardHeight(fitting: threeRows, boardWidth: boardWidth - 40)
            // The board's natural (compact) height: fills the screen on a phone
            // (where the cards aren't capped), stays compact on an iPad so the
            // spacers don't balloon.
            let boardHeight = reserved + CardBoard<EmptyView>.height(cardHeight: cardHeight)
            ScrollView(.vertical, showsIndicators: false) {
                puzzleColumn(cardHeight: cardHeight)
                    .padding(.horizontal, 20)
                    // Fix the board to its compact box (the fixed width also stops the
                    // VStack sizing to its widest child, the top bar, and bleeding off
                    // the right on narrow phones), then center it in the viewport.
                    .frame(width: boardWidth, height: boardHeight)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The centered puzzle column (top bar, target, cards, ops). Extracted from
    /// `body` so the type-checker can handle it once the width/height frame is
    /// applied around it.
    private func puzzleColumn(cardHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
            if multiplayer.phase == .playing {
                playerList
                    .padding(.top, 8)
            }
            // Guaranteed breathing room above/below the board, expanding to
            // absorb slack on tall devices so nothing crowds the card grid.
            Spacer(minLength: 18)
            targetCard
                .padding(.bottom, 18)
            cardGrid(cardHeight: cardHeight)
                .disabled(!boardInteractive)
                .opacity(boardInteractive ? 1 : 0.4)
            Spacer(minLength: 18)
            hintDisplay
            lockInBar
            operationRow
                .disabled(!boardInteractive)
                .opacity(boardInteractive ? 1 : 0.4)
                .padding(.top, 4)
            bottomRow
        }
    }

    /// The board can only be manipulated in solo play, in a `.firstToSolve` race
    /// (no buzz gate — everyone plays continuously), or — in a `.buzzIn` race —
    /// while I hold the lock-in. Otherwise you must buzz "Krypto!" first.
    private var boardInteractive: Bool {
        multiplayer.phase != .playing || multiplayer.roomMode == .firstToSolve || multiplayer.iHoldLock
    }

    // MARK: - Lock-in ("Krypto!")

    /// The race's buzz control: a big "Krypto!" button when the floor is open,
    /// a live countdown while I'm proving my solution, or a note while I wait out
    /// a turn I just missed. Hidden in solo play, once a winner is decided, and
    /// entirely in a `.firstToSolve` room — there's no floor to buzz for.
    @ViewBuilder
    private var lockInBar: some View {
        if multiplayer.phase == .playing, multiplayer.winnerIsMe == nil, multiplayer.roomMode == .buzzIn {
            if multiplayer.iHoldLock {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                    Text("Solve it! \(multiplayer.lockSecondsLeft)s")
                        .monospacedDigit()
                }
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 12)
            } else if multiplayer.opponentHoldsLock {
                EmptyView() // the opponent-solving overlay takes over the screen
            } else if multiplayer.canLockIn {
                Button { multiplayer.lockIn() } label: {
                    Label("Krypto!", systemImage: "bolt.fill")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.bottom, 12)
            } else {
                Text("You missed — buzz again in \(multiplayer.cooldownSecondsLeft)s")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Hint

    /// During a race the hint is a shared, attributed banner ("You/Alice used a
    /// hint"); in solo play it's just the plain suggestion line.
    @ViewBuilder
    private var hintDisplay: some View {
        if multiplayer.phase == .playing, let hint = multiplayer.sharedHint {
            VStack(spacing: 2) {
                Text("\(hint.requesterName) used a hint")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(hint.text)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)
            .transition(.opacity)
        } else if let hint = game.hint {
            // Multi-line so a revealed solution (one step per line) isn't
            // truncated to its first step.
            Text(hint)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(10)
                    .background(Theme.pill, in: Circle())
            }

            HStack(spacing: 5) {
                Image(systemName: "clock")
                Text(game.timeString)
                    .monospacedDigit()
                    // Past the break-even time the clock turns red: every
                    // further second now costs rating.
                    .foregroundStyle(pastTarget ? .red.opacity(0.85) : Theme.inkMuted)
                if let target = game.targetSeconds, multiplayer.phase != .playing {
                    Image(systemName: "scope")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .padding(.leading, 4)
                    Text(ContentView.formatSeconds(target))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize()
            .font(.system(.callout, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.pill, in: Capsule())
            .accessibilityLabel(game.targetSeconds.map { "Time \(game.timeString), target \(ContentView.formatSeconds($0))" } ?? "Time \(game.timeString)")

            Button { showStats = true } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(10)
                    .background(Theme.pill, in: Circle())
            }

            Spacer()

            if remote.flags.hintsEnabled && (multiplayer.phase != .playing || multiplayer.roomHintsEnabled) {
                Button {
                    if multiplayer.phase == .playing {
                        // Broadcast to the room so everyone sees the same hint and who asked.
                        multiplayer.requestHint(game.hintText())
                    } else {
                        game.showHint()
                    }
                } label: {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(10)
                        .background(Theme.pill, in: Circle())
                }
            }

            if multiplayer.phase == .playing {
                Button {
                    multiplayer.leave()
                    game.multiplayer = nil
                    if launchedForMultiplayer { dismiss() } else { game.newGame() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(10)
                        .background(Theme.pill, in: Circle())
                }
            }

            Button { showProfile = true } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(10)
                    .background(Theme.pill, in: Circle())
            }
        }
        // Matches the home screen's top inset so the bar doesn't hug the status bar.
        .padding(.top, 16)
        // Icon buttons and pills here are fixed-size chrome, not readable content —
        // cap Dynamic Type so huge accessibility text sizes don't blow the row past
        // the screen width (the puzzle content below still scales normally).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Shown under the top bar during an active race: everyone in the room with their
    /// race score, plus the room code. A visible list (rather than a single opponent
    /// pill) makes it clear the room isn't limited to just the two of you.
    private var playerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            playerRow(name: "You", score: multiplayer.myScore)
            ForEach(multiplayer.opponents) { opp in
                playerRow(name: opp.name, score: opp.score, presence: opp.presence)
            }
            if let code = multiplayer.roomCode {
                Text("Room \(code)")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
                    .monospaced()
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func playerRow(name: String, score: Int, presence: OpponentPresence? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 11, weight: .bold))
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let presence {
                OpponentPresenceRow(presence: presence)
            }
            Text("\(score)")
                .monospacedDigit()
        }
        .font(.system(.footnote, design: .rounded, weight: .semibold))
        .foregroundStyle(Theme.inkMuted)
        .frame(minWidth: 140, alignment: .leading)
    }

    // MARK: - Target

    private var targetCard: some View {
        VStack(spacing: 8) {
            TargetCard(value: game.target.description)
            if let target = game.targetSeconds, multiplayer.phase != .playing {
                // Break-even time for this player's rating on this puzzle:
                // under it the rating goes up, over it down.
                Label("Beat \(ContentView.formatSeconds(target))", systemImage: "scope")
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(pastTarget ? .red.opacity(0.85) : Theme.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.pill, in: Capsule())
            }
        }
    }

    // MARK: - Cards

    private func cardGrid(cardHeight: CGFloat) -> some View {
        // After a give-up the hand is all five cards again and the solution
        // reads best right under them, so it takes a strip beneath the rows
        // (the cards shrink to make room; the board's height doesn't change).
        let showsSolution = game.gaveUp && !game.revealedSolution.isEmpty
        return CardBoard(
            cards: game.cards,
            selected: game.selectedCardID.map { [$0] } ?? [],
            cardHeight: cardHeight,
            footerHeight: showsSolution ? SolutionStrip.height : 0,
            onTap: { game.tapCard($0) },
            onCombine: { game.combine(first: $0, second: $1, op: $2) },
            preselectedOp: game.selectedOp
        ) {
            SolutionStrip(
                steps: game.revealedSolution,
                header: game.ratingDelta.map {
                    "\(String(soloRating.rating - $0)) \u{2192} \(String(soloRating.rating))  (\(String($0)))"
                }
            )
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Operations

    private var operationRow: some View {
        HStack(spacing: 6) {
            ForEach(Operation.allCases) { op in
                Button { game.tapOperation(op) } label: {
                    Text(op.rawValue)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(game.selectedOp == op ? .white : Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(game.selectedOp == op ? Theme.button : Theme.pill)
                        )
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.6)))
        .padding(.bottom, 12)
    }

    // MARK: - Bottom

    /// The host can switch undo off for a room; solo play always allows it.
    private var undosAllowed: Bool {
        multiplayer.phase != .playing || multiplayer.roomUndosAllowed
    }

    private var bottomRow: some View {
        HStack(spacing: 14) {
            Button { game.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(game.canUndo ? Theme.inkDark : Theme.inkMuted.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!game.canUndo || !boardInteractive || !undosAllowed || game.isOver)
            .opacity(boardInteractive && undosAllowed && !game.isOver ? 1 : 0.4)

            Button {
                // Only route to the shared-room confirm when there's actually a
                // live room. A phase left stuck at `.playing` after an abnormal
                // exit (no roomCode) would otherwise show the confirm and then
                // no-op in `startNewGame`, leaving the old board in place.
                if multiplayer.phase == .playing, multiplayer.roomCode != nil {
                    // In a custom room only the host deals the next hand; a
                    // non-host's button just does nothing rather than desyncing
                    // their board from the room.
                    if !multiplayer.isCustomRoom || multiplayer.isHost {
                        showNewGameConfirm = true
                    }
                } else if game.isOver {
                    advanceAfterResult()
                } else {
                    // Solo play is rated, so there's no free "New Game" mid-puzzle:
                    // the way out is to see the solution and take the loss.
                    showGiveUpConfirm = true
                }
            } label: {
                Label(bottomActionTitle, systemImage: bottomActionIcon)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(.bottom, 8)
        // Fixed-height buttons — cap Dynamic Type so large accessibility text sizes
        // don't get clipped inside the 58pt-tall button frame.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - New game confirmation

    private var newGameConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { showNewGameConfirm = false }
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Start a New Game?")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text(multiplayer.isCustomRoom
                     ? "This deals a fresh hand for everyone in the room."
                     : "This deals a fresh hand for you and \(multiplayer.opponents.first?.name ?? "your opponent").")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                HStack(spacing: 12) {
                    Button {
                        showNewGameConfirm = false
                    } label: {
                        Text("Cancel")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        showNewGameConfirm = false
                        multiplayer.startNewGame()
                    } label: {
                        Text("Start")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(40)
        }
    }

    private var bottomActionTitle: String {
        if multiplayer.phase == .playing { return "New Game" }
        if game.isOver { return needsSignInToContinue ? "Sign in" : "Next Puzzle" }
        return "Solution"
    }

    private var bottomActionIcon: String {
        if multiplayer.phase == .playing { return "arrow.right" }
        if game.isOver { return needsSignInToContinue ? "person.crop.circle.badge.plus" : "arrow.right" }
        return "lightbulb.fill"
    }

    /// Deals the next puzzle — or, once a signed-out player has used up their
    /// free puzzles, opens the profile sheet's sign-in instead.
    private func advanceAfterResult() {
        resultDismissed = false
        if needsSignInToContinue { showProfile = true } else { game.newGame() }
    }

    /// Top-right X on a result card: closes it to show the finished board.
    private var closeResultButton: some View {
        Button { resultDismissed = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 32, height: 32)
                .background(Theme.pill, in: Circle())
        }
        .accessibilityLabel("Close")
    }

    // MARK: - Rated solo: give up / solution

    private var pastTarget: Bool {
        guard let target = game.targetSeconds, !game.isOver, multiplayer.phase != .playing else { return false }
        return game.elapsed > target
    }

    static func formatSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var giveUpConfirmOverlay: some View {
        let cost = game.puzzleModel.map { SoloRating.giveUpCost(model: $0) }
        return ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { showGiveUpConfirm = false }
            VStack(spacing: 16) {
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Show the Solution?")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text(cost.map { "This counts as a loss on this puzzle. You'll drop \($0) points. Finishing late costs less." }
                     ?? "This counts as a loss on this puzzle.")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                HStack(spacing: 12) {
                    Button { showGiveUpConfirm = false } label: {
                        Text("Keep Trying")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        showGiveUpConfirm = false
                        game.giveUp()
                    } label: {
                        Text("Show It")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            // Narrower outer margin than the other cards: "Keep Trying"
            // needs the width.
            .padding(24)
        }
    }

    /// "1200 → 1212 (+12)" under a result, with the target the solve was
    /// measured against. Empty when the puzzle wasn't rated.
    @ViewBuilder
    private var ratingResultLine: some View {
        if let delta = game.ratingDelta {
            VStack(spacing: 4) {
                // `String(_:)` sidesteps SwiftUI's localized number formatting,
                // which would render 1200 as "1,200".
                Text("\(String(soloRating.rating - delta)) \u{2192} \(String(soloRating.rating))  (\(delta >= 0 ? "+" : "")\(String(delta)))")
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(delta >= 0 ? Theme.accent : .red.opacity(0.85))
                TierResultLine(standing: soloRating.standing, change: soloRating.lastTierChange, tiers: remote.tiers)
                    .padding(.top, 2)
                if game.isSolved, let target = game.targetSeconds {
                    Text("Target was \(ContentView.formatSeconds(target))")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    /// Deals the next puzzle — or, once a signed-out player has used up their
    /// free puzzles, opens the profile sheet's sign-in instead.
    private var nextPuzzleButton: some View {
        Button {
            advanceAfterResult()
        } label: {
            Label(needsSignInToContinue ? "Sign in to keep playing" : "Next Puzzle",
                  systemImage: needsSignInToContinue ? "person.crop.circle.badge.plus" : "arrow.right")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .frame(height: 56)
                .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - Win overlay

    private var winOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("🎉")
                    .font(.system(size: 56))
                Text("Krypto!")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                Text("Solved in \(game.timeString)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                ratingResultLine
                nextPuzzleButton
                    .padding(.top, 8)
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .overlay(alignment: .topTrailing) { closeResultButton.padding(14) }
            .padding(40)
        }
    }

    // MARK: - Multiplayer overlays

    /// Shown to the opponent while a player is locked in: their solution streams in
    /// live, so you watch them prove it (and see if they'll finish before time).
    private var opponentSolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("\(multiplayer.displayName(for: multiplayer.lockHolder)) locked in")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text("Proving it… \(multiplayer.lockSecondsLeft)s")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)

                if multiplayer.opponentSteps.isEmpty {
                    Text("Thinking…")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(multiplayer.opponentSteps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                }

                Text("If they miss, the floor is yours.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(32)
        }
        .animation(.easeInOut(duration: 0.15), value: multiplayer.opponentSteps)
    }

    private func raceResultOverlay(won: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(won ? "🏆" : "😅")
                    .font(.system(size: 56))
                Text(won ? "You Won!" : "\(multiplayer.displayName(for: multiplayer.winnerID)) Won")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                if won {
                    Text("Solved in \(game.timeString)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                } else if let winner = multiplayer.opponents.first(where: { $0.id == multiplayer.winnerID }),
                          let time = winner.elapsed {
                    Text(String(format: "%@ solved it in %d:%02d", winner.name, time / 60, time % 60))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                if !multiplayer.winningSolution.isEmpty {
                    VStack(spacing: 4) {
                        Text(won ? "Your solution" : "Winning solution")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                        ForEach(Array(multiplayer.winningSolution.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                }
                rematchControls
                Button {
                    multiplayer.leave()
                    game.multiplayer = nil
                    game.newGame()
                } label: {
                    Label("Exit Multiplayer", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .frame(height: 56)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.top, 8)
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(40)
        }
    }

    @ViewBuilder
    private var rematchControls: some View {
        if multiplayer.isCustomRoom {
            if multiplayer.isHost {
                Button { multiplayer.startNewGame() } label: {
                    Label("New Game", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                Text("The host starts the next round.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        } else if multiplayer.opponentWantsRematch {
            VStack(spacing: 10) {
                Text("\(multiplayer.opponents.first?.name ?? "Opponent") wants a rematch")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 16) {
                    Button { multiplayer.declineRematch() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.red.opacity(0.75), in: Circle())
                    }
                    Button { multiplayer.requestRematch() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.green.opacity(0.8), in: Circle())
                    }
                }
            }
        } else if multiplayer.isWaitingOnRematchResponse {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for \(multiplayer.opponents.first?.name ?? "opponent") to accept the rematch…")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        } else {
            Button { multiplayer.requestRematch() } label: {
                Label("Rematch", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var waitingForOpponentOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView()
                Text("Solved in \(game.timeString) — waiting for result…")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Capsule().fill(.white).shadow(color: .black.opacity(0.1), radius: 10, y: 4))
            .padding(.bottom, 160)
        }
    }

    // MARK: - Stats

    private var statsSheet: some View {
        VStack(spacing: 24) {
            Text("Statistics")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            TierChip(standing: soloRating.standing, showsRating: true)
            HStack(spacing: 12) {
                statTile(value: "\(game.gamesWon)", label: "Solved")
                statTile(
                    value: game.bestTime > 0
                        ? String(format: "%d:%02d", game.bestTime / 60, game.bestTime % 60)
                        : "—",
                    label: "Best Time"
                )
                statTile(
                    value: game.averageTime > 0
                        ? String(format: "%d:%02d", game.averageTime / 60, game.averageTime % 60)
                        : "—",
                    label: "Avg Time"
                )
            }
            Spacer()
        }
        .padding(28)
        .presentationDetents([.height(360)])
        .presentationBackground(Theme.background)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 4)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct CardView: View {
    let card: Card
    let isSelected: Bool
    var height: CGFloat = 120
    var width: CGFloat? = nil
    var facing: Appearance.CardFacing = .oneWay
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardFace(text: card.value.description, isWhole: card.value.isWhole, height: height, width: width, facing: facing)
                .background(
                    RoundedRectangle(cornerRadius: 26)
                        .fill(Theme.cardColors[card.colorIndex % Theme.cardColors.count])
                        .shadow(color: .black.opacity(0.07), radius: 8, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(Theme.inkDark.opacity(isSelected ? 0.8 : 0), lineWidth: 3)
                )
                .scaleEffect(isSelected ? 1.05 : 1)
        }
        .animation(.spring(duration: 0.25), value: isSelected)
    }
}

#Preview {
    ContentView()
}
