import SwiftUI

/// One merge in a solve, expressed in terms of the *dealt* card slots (0–4)
/// rather than card ids, so a replay can be stored as plain JSON and rebuilt
/// later from the hand alone. The result always lands in `second`'s slot
/// (mirroring `GameViewModel.tapCard`, where the second card keeps its id).
struct ReplayMove: Codable, Equatable {
    let first: Int
    let op: String
    let second: Int
}

/// A complete recorded solve: the hand as dealt, its colours, and the moves.
struct SolveReplay: Codable, Equatable {
    let hand: [Int]
    let target: Int
    let colors: [Int]
    let moves: [ReplayMove]
}

/// Plays a recorded solve back on a card grid, on a loop: highlight the first
/// card, show the operator, highlight the second, merge them with a spring,
/// caption the step, and after the last step pause and start over. Purely
/// visual — nothing here touches game state.
struct SolveReplayView: View {
    let replay: SolveReplay
    var cardHeight: CGFloat = 90

    private struct ReplayCard: Identifiable, Equatable {
        let slot: Int
        var value: Fraction
        let colorIndex: Int
        var id: Int { slot }
        /// Display card with an id fixed per slot, so CardBoard keeps
        /// identity (and animates the merge) across redraws.
        var card: Card { Card(id: SolveReplayView.slotIDs[slot % SolveReplayView.slotIDs.count], value: value, colorIndex: colorIndex) }
    }

    fileprivate static let slotIDs: [UUID] = (0..<8).map { _ in UUID() }

    @State private var cards: [ReplayCard] = []
    @State private var highlighted: Set<Int> = []
    @State private var pendingOp: String?
    @State private var caption: String?
    @State private var stepNumber = 0


    var body: some View {
        VStack(spacing: 14) {
            // CardBoard keeps the full two-row height, so the panel doesn't
            // shrink step by step as cards merge away.
            CardBoard(
                cards: cards.map(\.card),
                selected: Set(cards.filter { highlighted.contains($0.slot) }.map(\.card.id)),
                cardHeight: cardHeight
            )
            .allowsHitTesting(false)
            .frame(maxWidth: 320)
            .animation(.spring(duration: 0.4), value: cards)

            // Fixed-height caption row so the grid doesn't jump between steps.
            HStack(spacing: 8) {
                if let pendingOp {
                    Text(pendingOp)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.button, in: Circle())
                        .transition(.scale.combined(with: .opacity))
                } else if let caption {
                    Text("Step \(stepNumber): \(caption)")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .transition(.opacity)
                } else {
                    Text("Your solve")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .transition(.opacity)
                }
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.2), value: pendingOp)
            .animation(.easeInOut(duration: 0.2), value: caption)
        }
        .task(id: replay) { await loop() }
    }

    private func reset() {
        cards = replay.hand.enumerated().map { index, value in
            ReplayCard(slot: index, value: Fraction(value), colorIndex: replay.colors.indices.contains(index) ? replay.colors[index] : index)
        }
        highlighted = []
        pendingOp = nil
        caption = nil
        stepNumber = 0
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func loop() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.25)) { reset() }
            await sleep(1.0)
            for (index, move) in replay.moves.enumerated() {
                guard !Task.isCancelled else { return }
                guard let firstIndex = cards.firstIndex(where: { $0.slot == move.first }),
                      let secondIndex = cards.firstIndex(where: { $0.slot == move.second }),
                      let op = Operation(rawValue: move.op),
                      let result = op.apply(cards[firstIndex].value, cards[secondIndex].value)
                else { break }
                let a = cards[firstIndex].value
                let b = cards[secondIndex].value

                caption = nil
                highlighted = [move.first]
                await sleep(0.5)
                pendingOp = move.op
                await sleep(0.45)
                highlighted = [move.first, move.second]
                await sleep(0.45)

                withAnimation(.spring(duration: 0.4)) {
                    pendingOp = nil
                    cards[secondIndex].value = result
                    cards.remove(at: firstIndex)
                    highlighted = [move.second]
                    stepNumber = index + 1
                    caption = "\(a) \(move.op) \(b) = \(result)"
                }
                await sleep(1.0)
            }
            guard !Task.isCancelled else { return }
            await sleep(1.6)
        }
    }
}
