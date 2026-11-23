import SwiftUI

struct RankedMatchView: View {
    @ObservedObject var ranked: RankedService
    @StateObject private var game = GameViewModel(dealsOwnPuzzle: false)
    @Environment(\.dismiss) private var dismiss

    /// Seconds of "opponent found" interstitial before the board (and the
    /// clock) start. The server delays a bot's first move by the same
    /// amount so the countdown costs the human nothing.
    static let introSeconds = 3
    @State private var introCountdown = RankedMatchView.introSeconds
    @State private var showIntro = true
    @State private var confirmLeave = false
    /// The result card can be closed (X) to look at the final board and the
    /// solution; a "Results" pill brings it back.
    @State private var showResult = true
    @State private var showSolution = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                targetCard
                    .padding(.bottom, 28)
                cardGrid
                Spacer()
                if let hint = game.hint {
                    Text(hint)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.bottom, 12)
                }
                if ranked.winnerIsMe == nil {
                    operationRow
                    Button { game.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(game.canUndo ? Theme.inkDark : Theme.inkMuted.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .disabled(!game.canUndo)
                } else {
                    postGameBar
                }
                myRatingFooter
            }
            .padding(.horizontal, 20)

            if showIntro {
                introOverlay
            }

            if let won = ranked.winnerIsMe, showResult {
                resultOverlay(won: won)
            }
        }
        .onChange(of: ranked.winnerIsMe) { _, result in
            guard result != nil else { return }
            showResult = true
            // The match is over either way; the clock stops where it stands.
            game.pause()
        }
        .onAppear {
            game.multiplayer = ranked
            // Board + clock start only after the intro countdown. `isPaused`
            // isn't used here: starting late is simpler than start-then-pause
            // and keeps `elapsed` meaning "time actually spent solving".
            runIntroCountdown()
        }
        .confirmationDialog("Leave this match?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave and forfeit", role: .destructive) { ranked.forfeit() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("Leaving counts as a loss and your rating will go down.")
        }
        .animation(.spring(duration: 0.35), value: game.cards)
        .animation(.easeInOut(duration: 0.25), value: ranked.winnerIsMe)
        .animation(.easeInOut(duration: 0.25), value: showIntro)
    }

    private func runIntroCountdown() {
        introCountdown = Self.introSeconds
        showIntro = true
        Task { @MainActor in
            while introCountdown > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                introCountdown -= 1
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            showIntro = false
            if let puzzle = ranked.puzzle {
                game.startShared(hand: puzzle.hand, target: puzzle.target)
            }
        }
    }

    // MARK: - Opponent found

    private var introOverlay: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Opponent found")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                Text(ranked.opponentName ?? "Player")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Tier rather than the number: reads at a glance, and keeps
                // the bots' rating band from standing out.
                if let standing = ranked.opponentStanding {
                    TierChip(standing: standing)
                }
                Text("First to solve wins. Get ready\u{2026}")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                Text("\(introCountdown)")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: introCountdown)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(game.timeString).monospacedDigit()
            }
            .lineLimit(1)
            .font(.system(.callout, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.pill, in: Capsule())

            // Opponent pill takes whatever width the timer and close button
            // leave, so long names truncate instead of pushing the layout.
            // Name + tier + presence when it fits; the tier is the first thing
            // to go so a long name and the presence pips stay readable.
            ViewThatFits(in: .horizontal) {
                opponentPill(showsTier: true)
                opponentPill(showsTier: false)
            }
            .lineLimit(1)
            .font(.system(.callout, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.pill, in: Capsule())

            Button {
                if ranked.winnerIsMe == nil {
                    confirmLeave = true
                } else {
                    ranked.leave()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 40, height: 40)
                    .background(Theme.pill, in: Circle())
            }
            .accessibilityLabel("Leave match")
        }
        .padding(.top, 8)
    }

    private func opponentPill(showsTier: Bool) -> some View {
        HStack(spacing: 6) {
            Text(ranked.opponentName ?? "Opponent")
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if showsTier, let standing = ranked.opponentStanding {
                Text(standing.label)
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            OpponentPresenceRow(presence: ranked.opponentPresence)
                .fixedSize()
        }
    }

    /// Replaces the old RANKED badge in the top bar: the player's current
    /// rating, tucked bottom-right so the top bar has room for the opponent.
    private var myRatingFooter: some View {
        HStack {
            Spacer()
            TierChip(standing: ranked.myStanding, showsRating: true, compact: true)
                .accessibilityLabel("Your rank \(ranked.myStanding?.label ?? "unranked"), rating \(ranked.newElo ?? ranked.myElo)")
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var targetCard: some View {
        TargetCard(value: game.target.description)
    }

    private var cardGrid: some View {
        // The review puts all five cards back; the solution takes a strip
        // under the rows, as on the Solo board after a give-up.
        let steps = showSolution ? solutionSteps : nil
        return CardBoard(
            cards: game.cards,
            selected: game.selectedCardID.map { [$0] } ?? [],
            cardHeight: 150,
            footerHeight: steps == nil ? 0 : SolutionStrip.height,
            onTap: { game.tapCard($0) },
            onCombine: { game.combine(first: $0, second: $1, op: $2) },
            preselectedOp: game.selectedOp
        ) {
            SolutionStrip(steps: steps ?? [])
        }
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

    // MARK: - After the game

    /// Replaces the operation row once the match is decided. Before the
    /// solution is revealed: Show Solution and a way back to the result card
    /// the player closed. After: the board is a review of the original hand
    /// (operators and Undo back, nothing live), with the solution in the grid.
    @ViewBuilder
    private var postGameBar: some View {
        if showSolution {
            operationRow
        }
        HStack(spacing: 10) {
            if showSolution {
                Button { game.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(game.canUndo ? Theme.inkDark : Theme.inkMuted.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!game.canUndo)
            } else {
                Button { revealSolution() } label: {
                    Label("Show Solution", systemImage: "lightbulb.fill")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            Button { showResult = true } label: {
                Label("Results", systemImage: "flag.checkered")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    /// Puts the original hand back next to the solution. Idempotent: the
    /// result card's link and the bar's button both land here.
    private func revealSolution() {
        guard !showSolution else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showSolution = true }
        if let puzzle = ranked.puzzle {
            game.startReview(hand: puzzle.hand, target: puzzle.target)
        }
    }

    /// One valid solution for the match's original hand, as display lines.
    /// Computed from `ranked.puzzle` rather than the live board, which the
    /// player may have reduced partway (or all the way) already.
    private var solutionSteps: [String]? {
        guard let puzzle = ranked.puzzle,
              let steps = Krypto.solve(puzzle.hand.map { Fraction($0) }, target: Fraction(puzzle.target))
        else { return nil }
        return steps.map { "\($0.a) \($0.op.rawValue) \($0.b) = \($0.result)" }
    }

    /// The action row at the bottom of the result card. Its shape follows
    /// the rematch negotiation: the plain New Game / Rematch pair by default,
    /// a waiting state with Cancel while the opponent decides, an
    /// Accept / Decline prompt when they asked us, and a short verdict line
    /// (declined / no response) that leaves New Game as the way forward.
    @ViewBuilder
    private var rematchSection: some View {
        let name = ranked.opponentName ?? "Your opponent"
        switch ranked.rematchState {
        case .incoming:
            VStack(spacing: 10) {
                Label("\(name) wants a rematch", systemImage: "arrow.counterclockwise")
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                HStack(spacing: 12) {
                    Button { ranked.declineRematch() } label: {
                        Text("Decline")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button { ranked.acceptRematch() } label: {
                        Label("Accept", systemImage: "checkmark")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        case .waitingForOpponent:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.inkMuted)
                    Text("Waiting for \(name)\u{2026}")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                Button { ranked.cancelRematchRequest() } label: {
                    Text("Cancel")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        case .declined, .noResponse:
            VStack(spacing: 10) {
                Text(ranked.rematchState == .declined ? "\(name) declined the rematch." : "No response from \(name).")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                newGameButton(primary: true)
            }
        case .none:
            HStack(spacing: 12) {
                newGameButton(primary: false)
                // Humans get asked (see `RankedService.requestRematch`); a bot
                // rematch re-queues straight away and the searching popup on
                // the Competition screen takes over as the cover closes.
                Button {
                    ranked.requestRematch()
                } label: {
                    Label("Rematch", systemImage: "arrow.counterclockwise")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(ranked.eloDelta == nil)
            }
        }
    }

    /// Plain re-queue: the cover closes as the phase leaves `.matched` and
    /// the searching popup takes over.
    private func newGameButton(primary: Bool) -> some View {
        Button {
            ranked.requestNewGame()
        } label: {
            Label("New Game", systemImage: "bolt.fill")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(primary ? .white : Theme.inkDark)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(primary ? Theme.button : Theme.pill, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(ranked.eloDelta == nil)
    }

    private func resultOverlay(won: Bool) -> some View {
        let iForfeited = ranked.forfeitedBy != nil && !won
        let theyForfeited = ranked.forfeitedBy != nil && won
        return ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button { showResult = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                            .frame(width: 32, height: 32)
                            .background(Theme.pill, in: Circle())
                    }
                    .accessibilityLabel("Close results and view the board")
                }
                .padding(.bottom, -8)
                Text(won ? "🏆" : (iForfeited ? "🏳️" : "😮"))
                    .font(.system(size: 56))
                Text(won ? "Ranked Win!" : (iForfeited ? "Forfeited" : "Ranked Loss"))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                if theyForfeited {
                    Text("Your opponent left the match.")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                } else if won {
                    Text("Solved in \(game.timeString)")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                } else if !iForfeited {
                    Text("Your opponent solved it first.")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
                if let delta = ranked.eloDelta, let newElo = ranked.newElo {
                    Text("\(String(newElo - delta)) \u{2192} \(String(newElo))  (\(delta >= 0 ? "+" : "")\(String(delta)))")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    TierResultLine(standing: ranked.myStanding, change: ranked.lastTierChange,
                                   tiers: Remote.shared.tiers, placementNote: ranked.placementNote)
                } else {
                    ProgressView().tint(Theme.inkMuted)
                }
                Button {
                    revealSolution()
                    showResult = false
                } label: {
                    Label("Show solution", systemImage: "lightbulb.fill")
                        .font(.system(.footnote, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                }
                rematchSection
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }
}
