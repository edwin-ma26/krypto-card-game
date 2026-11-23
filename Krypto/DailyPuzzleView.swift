import SwiftUI

struct DailyPuzzleView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var friends: FriendsService
    @StateObject private var daily = DailyPuzzleService()
    // Doesn't deal its own puzzle — `daily.load` hands it today's hand/target
    // via `startShared` once it's fetched (see `GameViewModel.dealsOwnPuzzle`).
    @StateObject private var game = GameViewModel(dealsOwnPuzzle: false)
    @Environment(\.dismiss) private var dismiss
    @State private var showPuzzlePreview = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch daily.phase {
            case .loading:
                ProgressView().tint(Theme.inkMuted)
            case .error(let message):
                errorState(message)
            case .ready:
                if daily.isCompletedToday {
                    completedState
                } else {
                    playState
                }
            }

            if showPuzzlePreview {
                puzzlePreviewOverlay
            }
        }
        .overlay(alignment: .top) {
            RankedRematchBanner(onAccept: {
                RankedService.shared.wantsCompetitionScreen = true
                dismiss()
            })
            // Clear the back/profile buttons in the corners.
            .padding(.top, 44)
            .animation(.easeInOut(duration: 0.25), value: RankedService.shared.hasIncomingRematchBanner)
        }
        // playState hangs its own back button in `topBar`; every other phase
        // (loading, error, and the "already completed today" screen) gets it
        // from this overlay instead.
        .overlay(alignment: .topLeading) {
            if daily.phase != .ready || daily.isCompletedToday {
                backButtonOverlay
            }
        }
        // Same idea for the profile button — playState has it in `topBar`,
        // everything else gets it from this overlay — so it's reachable from
        // anywhere in the daily puzzle flow, not just before you've played.
        .overlay(alignment: .topTrailing) {
            if daily.phase != .ready || daily.isCompletedToday {
                profileButtonOverlay
            }
        }
        .sheet(isPresented: $showProfile) { ProfileView(auth: auth, friends: friends) }
        .task {
            await daily.load(uid: auth.user?.uid)
            await daily.loadFriendsLeaderboard(friendUids: friends.friends.map(\.id))
            if !daily.isCompletedToday {
                game.multiplayer = nil
                // So a fastest-solve record on `PuzzleStats` can be attributed
                // to this player instead of the generic "solo" label.
                game.solverIdentity = auth.user?.uid ?? "anonymous"
                // Resumes right where a previous session of today's puzzle left
                // off (see `onDisappear` below), instead of restarting the clock.
                game.startShared(hand: daily.hand, target: daily.target, resumeElapsed: daily.savedElapsedSeconds ?? 0)
            }
        }
        // The friends list loads asynchronously at launch, so the fetch in
        // `.task` above can run against an empty (or stale) list if this
        // screen is opened quickly; refetch whenever the set of friends
        // actually changes so the leaderboard catches up.
        .onChange(of: friends.friends.map(\.id)) { _, ids in
            guard daily.phase == .ready else { return }
            Task { await daily.loadFriendsLeaderboard(friendUids: ids) }
        }
        .onDisappear {
            guard daily.phase == .ready, !daily.isCompletedToday, !game.isSolved else { return }
            game.syncElapsed()
            daily.saveProgress(elapsedSeconds: game.elapsed)
        }
        .onChange(of: game.isSolved) { _, solved in
            guard solved else { return }
            // `comparisonStats` was already fetched up front in `daily.load()`,
            // before the player even started, so the result screen shows
            // numbers instantly instead of waiting on a fetch. Refresh it once
            // this solve is recorded so Avg/Fastest pick up this player's own
            // just-finished solve too, rather than showing a pre-solve snapshot
            // forever.
            daily.saveSolveReplay(game.solveReplay)
            StatsLog.shared.recordDaily(dateKey: DailyPuzzleService.todayKeyUTC(), seconds: game.elapsed)
            Task {
                await daily.recordCompletion(uid: auth.user?.uid, elapsedSeconds: game.elapsed)
                await daily.refreshComparisonStats()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: daily.phase)
        .animation(.spring(duration: 0.35), value: game.cards)
        .animation(.easeInOut(duration: 0.2), value: showPuzzlePreview)
    }

    // MARK: - Error / already-completed states

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "flame.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
            Text(message)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { Task { await daily.load(uid: auth.user?.uid) } } label: {
                Text("Try Again")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 50)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var completedState: some View {
        VStack(spacing: 16) {
            Text("🔥")
                .font(.system(size: 56))
            Text(auth.isSignedIn ? "\(daily.streak)-Day Streak" : "Solved today!")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark)
            Text("You've solved today's puzzle. Come back tomorrow!")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if auth.isSignedIn && daily.longestStreak > daily.streak {
                Text("Best: \(daily.longestStreak) days")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            resultsSection(mySeconds: daily.mySolveSeconds)
            Button { showPuzzlePreview = true } label: {
                Label("View Puzzle", systemImage: "eye.fill")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .frame(height: 52)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Results (gated)

    /// Comparison chart + friends leaderboard for signed-in players. An
    /// anonymous player gets the same chart blurred behind one sign-in
    /// button: the solve is still recorded under their anonymous uid (and
    /// the streak with it), and linking an account keeps that uid, so the
    /// numbers simply unlock in place once they sign in.
    @ViewBuilder
    private func resultsSection(mySeconds: Int?) -> some View {
        if auth.isSignedIn {
            comparisonStatsView(mySeconds: mySeconds)
            friendsLeaderboardView(mySeconds: mySeconds)
        } else {
            ZStack {
                comparisonStatsView(mySeconds: mySeconds)
                    .blur(radius: 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text("See how you compare")
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                        .foregroundStyle(Theme.inkDark)
                    Text("Sign in to see today's times, keep your streak, and race your friends.")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                    Button { showProfile = true } label: {
                        Text("Sign In")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .frame(height: 46)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.92)))
                .padding(.horizontal, 28)
            }
            .frame(minHeight: 180)
        }
    }

    // MARK: - Compare against others

    /// Histogram of today's solve times with Best / Avg / You markers, plus
    /// the headline numbers underneath. Silent (renders nothing) if stats
    /// haven't loaded; falls back to a one-liner if nobody's solved it yet.
    /// Today's aggregate, or the debug-only sample distribution when the
    /// app was launched with `KRYPTO_DEMO_STATS=1` (see `DemoStats`).
    private var comparisonStats: PuzzleStats.Summary? {
        #if DEBUG
        if DemoStats.isEnabled { return DemoStats.summary }
        #endif
        return daily.comparisonStats
    }

    @ViewBuilder
    private func comparisonStatsView(mySeconds: Int?) -> some View {
        if let stats = comparisonStats, stats.timesSolved > 0 {
            VStack(spacing: 10) {
                SolveTimeChart(
                    histogram: stats.histogram,
                    fastestSeconds: stats.fastestSolveSeconds,
                    averageSeconds: stats.averageSolveSeconds,
                    mySeconds: mySeconds
                )
                if let mySeconds, let percentile = stats.percentile(forElapsedSeconds: mySeconds) {
                    Text("Faster than \(percentile)% of solvers")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        } else if let mySeconds {
            // Nobody else on record yet as of this snapshot — still show the
            // player's own time even though there's nothing to compare it to.
            Text("You: \(Self.formatSeconds(mySeconds)) — first solve on record!")
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
                .padding(.top, 2)
        }
    }

    private func isMyFastestSolve(_ stats: PuzzleStats.Summary) -> Bool {
        guard let uid = auth.user?.uid else { return false }
        return stats.fastestSolveBy == uid
    }

    static func formatSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Friends leaderboard

    private struct LeaderboardEntry: Identifiable {
        let id: String
        let displayName: String
        let solveSeconds: Int
        let isMe: Bool
    }

    /// `daily.friendsLeaderboard` plus this player's own row (if they've
    /// solved today), fastest first. `daily.friendsLeaderboard` only ever
    /// contains friends who've completed *today's* puzzle, so nothing here
    /// needs to filter out friends who haven't played yet.
    private func friendsLeaderboardEntries(mySeconds: Int?) -> [LeaderboardEntry] {
        var entries = daily.friendsLeaderboard.map {
            LeaderboardEntry(id: $0.id, displayName: $0.displayName, solveSeconds: $0.solveSeconds, isMe: false)
        }
        if let mySeconds, let uid = auth.user?.uid {
            entries.append(LeaderboardEntry(id: uid, displayName: "You", solveSeconds: mySeconds, isMe: true))
        }
        return entries.sorted { $0.solveSeconds < $1.solveSeconds }
    }

    /// Silent (renders nothing) if no friend — and not this player either —
    /// has completed today's puzzle yet.
    @ViewBuilder
    private func friendsLeaderboardView(mySeconds: Int?) -> some View {
        let entries = friendsLeaderboardEntries(mySeconds: mySeconds)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Friends")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
                VStack(spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(.footnote, design: .rounded, weight: .bold))
                                .foregroundStyle(Theme.inkMuted)
                                .frame(width: 16, alignment: .leading)
                            Text(entry.isMe ? "You" : entry.displayName)
                                .font(.system(.footnote, design: .rounded, weight: entry.isMe ? .heavy : .semibold))
                                .foregroundStyle(entry.isMe ? Theme.inkDark : Theme.inkMuted)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.formatSeconds(entry.solveSeconds))
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(entry.isMe ? Theme.accent : Theme.inkMuted)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
        }
    }

    // MARK: - Playable board

    private var playState: some View {
        ZStack {
            // Size the cards to the height left after the fixed chrome (top bar,
            // "beat" line, target, ops, Undo), the same way ContentView does, so
            // the board fits a 667pt SE / zoomed-display screen instead of
            // pushing the top bar under the status bar and Undo off the bottom.
            // The ScrollView is a safety net for very large Dynamic Type.
            GeometryReader { geo in
                let reserved: CGFloat = 440
                let threeRows = 3 * min(300, max(66, (geo.size.height - reserved) / 3))
                let cardHeight = CardBoard<EmptyView>.cardHeight(fitting: threeRows, boardWidth: min(geo.size.width, 440) - 40)
                let boardHeight = reserved + CardBoard<EmptyView>.height(cardHeight: cardHeight)
                ScrollView(.vertical, showsIndicators: false) {
                    playColumn(cardHeight: cardHeight)
                        .padding(.horizontal, 20)
                        .frame(width: geo.size.width, height: boardHeight)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if game.isSolved {
                solvedOverlay
            }
        }
    }

    private func playColumn(cardHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            // The comparison stats land a beat after the board appears.
            // Keep this line's slot reserved (invisible until the number
            // exists) so the target and cards don't jump up when it does.
            let beatTarget = daily.comparisonStats?.targetSeconds
            Text(beatTarget.map { "Can you beat \(Self.formatSeconds($0))?" } ?? " ")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(beatTarget == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: beatTarget == nil)
                .padding(.bottom, 10)
            targetCard
                .padding(.bottom, 28)
            cardGrid(cardHeight: cardHeight)
            Spacer()
            if let hint = game.hint {
                Text(hint)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            operationRow
            // No hints in the daily puzzle — same rule as ranked
            // (RankedMatchView): everyone gets the same hand, so a hint
            // here would be a shortcut against the shared streak/leaderboard.
            Button { game.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(game.canUndo ? Theme.inkDark : Theme.inkMuted.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!game.canUndo)
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        // Five chips across a 335pt column on the SE: the streak and DAILY
        // labels keep their natural width (otherwise the HStack wraps/clips
        // them first) and a long resumed timer is the one thing that gives,
        // by scaling its digits down a touch.
        HStack(spacing: 8) {
            backButton

            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(game.timeString).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(.callout, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.pill, in: Capsule())

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                Text("\(daily.streak)").monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            .font(.system(.callout, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.pill, in: Capsule())

            Spacer(minLength: 0)

            Text("DAILY")
                .font(.system(.caption, design: .rounded, weight: .heavy))
                .kerning(1)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.pill, in: Capsule())

            profileButton
        }
        .padding(.top, 8)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .padding(10)
                .background(Theme.pill, in: Circle())
        }
    }

    private var backButtonOverlay: some View {
        backButton
            .padding(.leading, 20)
            .padding(.top, 8)
    }

    private var profileButton: some View {
        Button { showProfile = true } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .padding(10)
                .background(Theme.pill, in: Circle())
        }
    }

    private var profileButtonOverlay: some View {
        profileButton
            .padding(.trailing, 20)
            .padding(.top, 8)
    }

    private var targetCard: some View {
        TargetCard(value: game.target.description)
    }

    /// The dealt hand as display-only cards with ids fixed per slot, so the
    /// preview doesn't re-identify (and re-animate) them on every redraw.
    private static let previewSlotIDs: [UUID] = (0..<8).map { _ in UUID() }
    static func previewCards(_ hand: [Int]) -> [Card] {
        hand.enumerated().map { index, value in
            Card(id: previewSlotIDs[index % previewSlotIDs.count], value: Fraction(value), colorIndex: index)
        }
    }

    private func cardGrid(cardHeight: CGFloat) -> some View {
        // CardBoard keeps its full two-row height however many cards remain,
        // so the target above doesn't slide as the hand merges away.
        CardBoard(
            cards: game.cards,
            selected: game.selectedCardID.map { [$0] } ?? [],
            cardHeight: cardHeight,
            onTap: { game.tapCard($0) },
            onCombine: { game.combine(first: $0, second: $1, op: $2) },
            preselectedOp: game.selectedOp
        )
        .frame(maxWidth: 400)
    }

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

    private var solvedOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("🔥")
                    .font(.system(size: 56))
                Text(auth.isSignedIn ? "\(daily.streak)-Day Streak" : "Solved!")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                Text("Solved in \(game.timeString)")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                resultsSection(mySeconds: game.elapsed)
                HStack(spacing: 12) {
                    Button { showPuzzlePreview = true } label: {
                        Label("View Puzzle", systemImage: "eye.fill")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 24)
            }
            // No card-level horizontal padding (each row brings its own) and
            // a narrow outer margin, so the solve-time chart gets a usable
            // width on a phone.
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
        }
    }

    // MARK: - View Puzzle

    /// A read-only look at today's original hand+target, built straight from
    /// `daily.hand`/`daily.target` rather than `game` — `game`'s cards are
    /// already reduced down to the solved result by this point, and a
    /// tappable board here would risk re-triggering `checkWin`/`PuzzleStats`
    /// for an already-recorded solve.
    private var puzzlePreviewOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { showPuzzlePreview = false }
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Target")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .textCase(.uppercase)
                        .kerning(1.5)
                        .foregroundStyle(Theme.inkMuted)
                    Text("\(daily.target)")
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.inkDark)
                }
                // Replays this player's own solve on a loop when we have it
                // (just solved, or saved from earlier today); otherwise the
                // plain dealt hand.
                if let replay = game.solveReplay ?? daily.savedSolveReplay, !replay.moves.isEmpty {
                    SolveReplayView(replay: replay)
                } else {
                    CardBoard(cards: Self.previewCards(daily.hand), cardHeight: 90)
                        .allowsHitTesting(false)
                        .frame(maxWidth: 320)
                }
                Button { showPuzzlePreview = false } label: {
                    Text("Close")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .frame(height: 50)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(40)
        }
    }
}

// MARK: - Solve-time distribution

/// Today's solve-time distribution as a smoothed density curve: a Gaussian
/// kernel is dropped on the midpoint of each 10-second bucket
/// (`PuzzleStats.bucket`), weighted by that bucket's solve count, and the
/// sum is drawn fast-to-slow with a soft fill underneath. Dashed markers sit
/// at the fastest and average times, a solid accent marker at this player's
/// own. Labels live in a strip above the curve and step aside (drop) when
/// two markers would collide, since the footer repeats every number anyway.
private struct SolveTimeChart: View {
    let histogram: [Int]
    let fastestSeconds: Int?
    let averageSeconds: Int?
    let mySeconds: Int?

    private let curveHeight: CGFloat = 88
    /// Two rows of marker labels ("You 1:18", "Avg 4:07", …) above the curve;
    /// a label that would overlap one already placed drops to the lower row.
    private let labelRowHeight: CGFloat = 18
    private var labelStripHeight: CGFloat { labelRowHeight * 2 }
    /// Minimum horizontal gap between two label centres on the same row.
    private let labelSpacing: CGFloat = 78

    private struct MarkerLabel: Identifiable {
        let id: String
        let text: String
        let x: CGFloat
        let row: Int
        let color: Color
        let emphasized: Bool
    }

    /// Lays out the marker labels fastest-priority: You first, then Avg, then
    /// Best. Best gets folded into You's label when they coincide (a player
    /// who holds the day's fastest time), and any two markers that collide
    /// on the top row split across the two rows instead of hiding.
    private func markerLabels(myX: CGFloat?, avgX: CGFloat?, bestX: CGFloat?, width: CGFloat) -> [MarkerLabel] {
        var placed: [MarkerLabel] = []
        func row(for x: CGFloat) -> Int {
            placed.contains { $0.row == 0 && abs($0.x - x) < labelSpacing } ? 1 : 0
        }
        func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 36), width - 36) }

        let bestFoldsIntoYou = myX.flatMap { m in bestX.map { abs($0 - m) < 6 } } ?? false
        if let myX, let mySeconds {
            let text = bestFoldsIntoYou
                ? "You \(DailyPuzzleView.formatSeconds(mySeconds)) · Best"
                : "You \(DailyPuzzleView.formatSeconds(mySeconds))"
            placed.append(MarkerLabel(id: "you", text: text, x: clamp(myX), row: 0, color: Theme.accent, emphasized: true))
        }
        if let avgX, let averageSeconds {
            placed.append(MarkerLabel(id: "avg", text: "Avg \(DailyPuzzleView.formatSeconds(averageSeconds))", x: clamp(avgX), row: row(for: clamp(avgX)), color: Theme.inkMuted, emphasized: false))
        }
        if let bestX, let fastestSeconds, !bestFoldsIntoYou {
            let x = clamp(bestX)
            // Both rows taken at this spot: skip rather than overprint.
            let collidesRow1 = placed.contains { $0.row == 1 && abs($0.x - x) < labelSpacing }
            let r = row(for: x)
            if !(r == 1 && collidesRow1) {
                placed.append(MarkerLabel(id: "best", text: "Best \(DailyPuzzleView.formatSeconds(fastestSeconds))", x: x, row: r, color: Theme.inkMuted, emphasized: false))
            }
        }
        return placed
    }

    /// The time axis always covers at least 0–2 minutes, and stretches to
    /// fit the slowest thing it has to show (the last non-empty bucket, the
    /// average, this player's time), rounded up to the next 30 seconds so
    /// the right edge isn't a marker sitting exactly on the border.
    private var axisSeconds: Double {
        let bucket = PuzzleStats.bucketSeconds
        let slowestBucketEnd = histogram.lastIndex(where: { $0 > 0 }).map { ($0 + 1) * bucket } ?? 0
        let needed = [120, slowestBucketEnd, averageSeconds ?? 0, mySeconds ?? 0, fastestSeconds ?? 0].max() ?? 120
        let roundedUp = Int((Double(needed) / 30).rounded(.up)) * 30
        return Double(max(120, roundedUp))
    }

    /// Kernel width in seconds. Wide enough that a handful of solves reads
    /// as a shape rather than a row of spikes, narrow enough that a fast
    /// cluster and a slow cluster stay visibly separate; scales with the
    /// axis so a long tail doesn't degrade into a row of needles.
    private var bandwidthSeconds: Double { max(14, axisSeconds / 10) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Today's solve times")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)
                Spacer()
                Text("0:00 → \(DailyPuzzleView.formatSeconds(Int(axisSeconds)))")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }

            GeometryReader { geo in
                let width = geo.size.width
                let myX = mySeconds.map { x(forSeconds: $0, width: width) }
                let bestX = fastestSeconds.map { x(forSeconds: $0, width: width) }
                let avgX = averageSeconds.map { x(forSeconds: $0, width: width) }
                let labels = markerLabels(myX: myX, avgX: avgX, bestX: bestX, width: width)
                let curve = densityPoints(width: width)

                ZStack(alignment: .bottomLeading) {
                    // Soft fill under the curve.
                    Path { path in
                        guard let first = curve.first, let last = curve.last else { return }
                        path.move(to: CGPoint(x: first.x, y: labelStripHeight + curveHeight))
                        for point in curve { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: last.x, y: labelStripHeight + curveHeight))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Theme.inkMuted.opacity(0.32), Theme.inkMuted.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // The curve itself.
                    Path { path in
                        guard let first = curve.first else { return }
                        path.move(to: first)
                        for point in curve.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Theme.inkMuted.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    Rectangle()
                        .fill(Theme.inkMuted.opacity(0.35))
                        .frame(width: width, height: 1)

                    if let bestX, !labels.contains(where: { $0.id == "you" && $0.text.hasSuffix("Best") }) {
                        markerLine(x: bestX, dashed: true, color: Theme.inkMuted)
                    }
                    if let avgX {
                        markerLine(x: avgX, dashed: true, color: Theme.inkMuted)
                    }
                    if let myX {
                        markerLine(x: myX, dashed: false, color: Theme.accent)
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2.5))
                            .position(x: myX, y: curveHeight + labelStripHeight)
                    }

                    ForEach(labels) { label in
                        Text(label.text)
                            .font(.system(.caption, design: .rounded, weight: label.emphasized ? .heavy : .bold))
                            .foregroundStyle(label.color)
                            .fixedSize()
                            .position(x: label.x, y: labelRowHeight * (CGFloat(label.row) + 0.5))
                    }
                }
            }
            .frame(height: curveHeight + labelStripHeight + 6)
        }
    }

    /// Samples the kernel density estimate across the chart width, already
    /// mapped into view coordinates (y grows downward; the peak touches the
    /// top of the curve area). Each bucket contributes a Gaussian centred on
    /// its midpoint, weighted by its count.
    private func densityPoints(width: CGFloat) -> [CGPoint] {
        let span = axisSeconds
        let half = Double(PuzzleStats.bucketSeconds) / 2
        let centers = histogram.enumerated().compactMap { index, count -> (Double, Double)? in
            count > 0 ? (Double(index * PuzzleStats.bucketSeconds) + half, Double(count)) : nil
        }
        guard !centers.isEmpty else { return [] }

        let sampleCount = 72
        var values: [Double] = []
        values.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let seconds = span * Double(i) / Double(sampleCount)
            let density = centers.reduce(0.0) { sum, kernel in
                let z = (seconds - kernel.0) / bandwidthSeconds
                return sum + kernel.1 * exp(-0.5 * z * z)
            }
            values.append(density)
        }
        let peak = max(values.max() ?? 1, .leastNonzeroMagnitude)
        let floor = labelStripHeight + curveHeight
        return values.enumerated().map { i, value in
            CGPoint(
                x: width * CGFloat(i) / CGFloat(sampleCount),
                y: floor - CGFloat(value / peak) * (curveHeight - 4)
            )
        }
    }

    private func markerLine(x: CGFloat, dashed: Bool, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: labelStripHeight))
            path.addLine(to: CGPoint(x: x, y: labelStripHeight + curveHeight))
        }
        .stroke(color, style: StrokeStyle(lineWidth: dashed ? 1.5 : 2.5, dash: dashed ? [4, 4] : []))
    }

    /// Horizontal position for a solve time, linear across `axisSeconds`.
    private func x(forSeconds seconds: Int, width: CGFloat) -> CGFloat {
        let clamped = min(max(Double(seconds), 0), axisSeconds)
        return CGFloat(clamped / axisSeconds) * width
    }
}

#if DEBUG
/// Debug-build hook: launch with `KRYPTO_DEMO_STATS=1` to render the result
/// screen's chart against a fuller sample distribution (a few dozen solves
/// shaped like a typical day) instead of today's real, possibly sparse,
/// numbers — for eyeballing the layout without waiting on real players.
enum DemoStats {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["KRYPTO_DEMO_STATS"] == "1" }
    static let summary = PuzzleStats.Summary(
        timesDealt: 1, timesSolved: 41, averageSolveSeconds: 42,
        fastestSolveSeconds: 11, fastestSolveBy: "demo", estimatedSolveSeconds: nil,
        solveTimeBuckets: [0: 1, 1: 6, 2: 9, 3: 8, 4: 6, 5: 4, 6: 3, 7: 2, 8: 1, 14: 1, 25: 1]
    )
}
#endif
