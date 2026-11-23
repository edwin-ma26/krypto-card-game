import SwiftUI

/// The same-phone Multiplayer board. The phone lies flat between two players:
/// each player gets their own half, a row of the five cards with the target
/// under it, the far half drawn upside down and a divider between. Each player has a
/// buzz bar at their own edge of the screen, and the solving controls turn to
/// face whoever holds the lock.
struct SamePhoneView: View {
    @StateObject private var match: SamePhoneMatch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showExitConfirm = false

    init(settings: SamePhoneMatch.Settings) {
        _match = StateObject(wrappedValue: SamePhoneMatch(settings: settings))
    }

    private var game: GameViewModel { match.game }

    private var boardInteractive: Bool { match.lockHolder != nil }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            GeometryReader { geo in
                // Two buzz bars, two targets, the divider, hint/ops/undo rows
                // and gutters; the two card rows share what's left.
                let reserved: CGFloat = 600
                let rowBudget = max(60, (geo.size.height - reserved) / 2)
                let cardWidth = CardBoard<EmptyView>.cardWidth(boardWidth: geo.size.width - 40, spacing: rowSpacing, layout: .row)
                let cardHeight = min(cardWidth * 1.45, rowBudget)
                // The solving controls sit at the solver's end of the phone:
                // below the cards for the near player, above them (and upside
                // down) for the far player, so nobody reaches across the board.
                let farSolving = match.lockHolder == .far
                VStack(spacing: 0) {
                    playerStrip(.far)
                        .rotationEffect(.degrees(180))
                        .padding(.top, 6)
                    if farSolving {
                        solverControls
                            .rotationEffect(.degrees(180))
                            .padding(.top, 10)
                    }
                    Spacer(minLength: 10)
                    VStack(spacing: boardGap) {
                        playerHalf(cardHeight: cardHeight)
                            .rotationEffect(.degrees(180))
                        divider
                        playerHalf(cardHeight: cardHeight)
                    }
                    Spacer(minLength: 10)
                    if !farSolving {
                        solverControls
                            .disabled(!boardInteractive)
                            .opacity(boardInteractive ? 1 : 0.45)
                    }
                    playerStrip(.near)
                        .padding(.bottom, 6)
                }
                .padding(.horizontal, 20)
                .frame(width: geo.size.width, height: geo.size.height)
            }

            if let winner = match.winner {
                resultOverlay(winner: winner)
            }
            if showExitConfirm {
                exitConfirmOverlay
            }
        }
        .animation(.spring(duration: 0.35), value: game.cards)
        .animation(.easeInOut(duration: 0.25), value: match.floor)
        .animation(.easeInOut(duration: 0.2), value: showExitConfirm)
        .statusBarHidden()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { game.resume() } else { game.pause() }
        }
        .onChange(of: showExitConfirm) { _, shown in
            if shown { game.pause() } else { game.resume() }
        }
    }

    // MARK: - Player strips

    /// A player's edge of the board: their score, and the buzz bar in whatever
    /// state the floor is in for them. Drawn the right way up for the near
    /// player; the caller flips it for the far one.
    private func playerStrip(_ player: SamePhoneMatch.Player) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.title.uppercased())
                    .font(.system(.caption2, design: .rounded, weight: .heavy))
                    .kerning(0.8)
                    .foregroundStyle(Theme.inkMuted)
                Text("\(match.scores[player] ?? 0)")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkDark)
            }
            .frame(width: 72, alignment: .leading)

            buzzBar(player)

            // Only the near player gets the exit control; one is enough and it
            // keeps the far strip a mirror of the near one otherwise.
            if player == .near {
                Button { showExitConfirm = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 44, height: 44)
                        .background(Theme.pill, in: Circle())
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder
    private func buzzBar(_ player: SamePhoneMatch.Player) -> some View {
        switch match.floor {
        case .locked(let holder) where holder == player:
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                Text("Solve it! \(match.lockSecondsLeft)s").monospacedDigit()
            }
            .font(.system(.headline, design: .rounded, weight: .heavy))
            .foregroundStyle(Theme.inkDark)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
        case .locked:
            Text("\(player.other.title) is solving…")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        case .won(let winner):
            Text(winner == player ? "You got it!" : "\(winner.title) got it")
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(winner == player ? Theme.accent : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        case .open:
            if let wait = match.cooldowns[player] {
                Text("Missed — buzz again in \(wait)s")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            } else {
                Button { match.buzz(player) } label: {
                    Label("Krypto!", systemImage: "bolt.fill")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .accessibilityLabel("\(player.title) buzz in")
            }
        }
    }

    // MARK: - Board

    private let rowSpacing: CGFloat = 10
    /// The one gap used between row, target and divider on both halves.
    private let boardGap: CGFloat = 14

    /// One player's half of the table: their row of cards with the target
    /// below it, nearest them. The caller flips the far player's copy.
    private func playerHalf(cardHeight: CGFloat) -> some View {
        VStack(spacing: boardGap) {
            cardRow(cardHeight: cardHeight)
            TargetCard(value: game.target.description, facing: .oneWay)
        }
    }

    private var divider: some View {
        Capsule()
            .fill(Theme.inkDark.opacity(0.12))
            .frame(height: 2)
            .padding(.horizontal, 24)
    }

    /// One player's row of the hand. Both rows show the same cards and the
    /// same selection; the caller flips the far player's copy.
    private func cardRow(cardHeight: CGFloat) -> some View {
        CardBoard(
            cards: game.cards,
            selected: game.selectedCardID.map { [$0] } ?? [],
            cardHeight: cardHeight,
            facing: .oneWay,
            layout: .row,
            spacing: rowSpacing,
            onTap: { game.tapCard($0) },
            onCombine: { game.combine(first: $0, second: $1, op: $2) },
            preselectedOp: game.selectedOp
        )
        .frame(maxWidth: .infinity)
        .disabled(!boardInteractive)
        .opacity(boardInteractive ? 1 : 0.45)
    }

    /// Hint line, operation row and undo/hint buttons — the part of the board
    /// that has a reading direction. Laid out for the near player; the caller
    /// flips and moves it for the far one.
    private var solverControls: some View {
        VStack(spacing: 0) {
            hintDisplay
            HStack(spacing: 6) {
                ForEach(Operation.allCases) { op in
                    Button { game.tapOperation(op) } label: {
                        Text(op.rawValue)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(game.selectedOp == op ? .white : Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(game.selectedOp == op ? Theme.button : Theme.pill)
                            )
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.6)))
            .padding(.bottom, 10)

            HStack(spacing: 14) {
                if match.settings.undosAllowed {
                    Button { game.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(game.canUndo ? Theme.inkDark : Theme.inkMuted.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!game.canUndo)
                }
                if match.settings.hintsEnabled {
                    Button {
                        if let holder = match.lockHolder { match.requestHint(from: holder) }
                    } label: {
                        Label("Hint", systemImage: "lightbulb.fill")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.bottom, 14)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    @ViewBuilder
    private var hintDisplay: some View {
        if let hint = match.sharedHint {
            Text(hint.text)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)
                .transition(.opacity)
        }
    }

    // MARK: - Round result

    /// Faces the winner, who is the one most likely to reach for Next Round.
    private func resultOverlay(winner: SamePhoneMatch.Player) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("🏆")
                    .font(.system(size: 52))
                Text("\(winner.title) wins!")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                Text(String(format: "Solved in %d:%02d", match.winningTime / 60, match.winningTime % 60))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                Text("\(match.scores[.near] ?? 0) – \(match.scores[.far] ?? 0)")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityLabel("Score: Player 1 \(match.scores[.near] ?? 0), Player 2 \(match.scores[.far] ?? 0)")
                if !match.winningSolution.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(match.winningSolution.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                }
                Button { match.nextRound() } label: {
                    Label("Next Round", systemImage: "arrow.right")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .frame(height: 56)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.top, 6)
                Button { dismiss() } label: {
                    Text("Exit")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(36)
            .rotationEffect(.degrees(winner == .far ? 180 : 0))
        }
    }

    // MARK: - Exit

    private var exitConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { showExitConfirm = false }
            VStack(spacing: 14) {
                Text("Leave the match?")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text("The score resets when you come back.")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 12) {
                    Button { showExitConfirm = false } label: {
                        Text("Keep Playing")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkDark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Button { dismiss() } label: {
                        Text("Leave")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            )
            .padding(32)
        }
    }
}
