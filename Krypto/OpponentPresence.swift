import SwiftUI

/// What the local client knows about an opponent's live state, shared by the
/// casual room and the ranked match so both screens render presence the same way.
struct OpponentPresence: Equatable {
    var cardsLeft: Int = 5
    /// Last time the opponent touched their board (server timestamp), if the
    /// match doc carries one. `nil` means the field never arrived.
    var lastActiveAt: Date?
    /// Server bots don't send heartbeats; treat them as always engaged.
    var alwaysActive = false
    var hasSolved = false

    /// A fresh deal has 5 cards; every combine removes one, so a solve is 4 steps.
    static let totalSteps = 4
    var stepsDone: Int { min(Self.totalSteps, max(0, 5 - cardsLeft)) }

    /// Heartbeats are throttled to one write every few seconds; anything inside
    /// this window still counts as "playing right now".
    static let activeWindow: TimeInterval = 8

    func isActive(at now: Date) -> Bool {
        if hasSolved { return false }
        if alwaysActive { return true }
        guard let lastActiveAt else { return false }
        return now.timeIntervalSince(lastActiveAt) < Self.activeWindow
    }
}

/// Four small card-shaped pips that fill in as the opponent combines cards.
/// The newest pip pops in with a spring and the local player gets a light tap.
struct OpponentProgressDots: View {
    let stepsDone: Int
    var solved = false
    var haptics = true

    @State private var popIndex: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<OpponentPresence.totalSteps, id: \.self) { index in
                let filled = index < stepsDone
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(filled ? Theme.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(filled ? Theme.accent : Theme.inkMuted.opacity(0.35), lineWidth: 1.5)
                    )
                    .frame(width: 9, height: 12)
                    .scaleEffect(popIndex == index ? 1.45 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: popIndex)
                    .animation(.easeOut(duration: 0.15), value: filled)
            }
            if solved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onChange(of: stepsDone) { old, new in
            guard new > old else { return }
            if haptics { Haptics.light() }
            popIndex = new - 1
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                if popIndex == new - 1 { popIndex = nil }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(solved ? "Opponent solved" : "Opponent \(stepsDone) of \(OpponentPresence.totalSteps) steps")
    }
}

/// A small dot that breathes while the opponent is actively playing and goes
/// grey once they've been quiet for a while (backgrounded, distracted, gone).
struct ActivityDot: View {
    let active: Bool
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(active ? Color.green : Theme.inkMuted.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay {
                if active {
                    Circle()
                        .stroke(Color.green.opacity(breathe ? 0 : 0.6), lineWidth: 2)
                        .scaleEffect(breathe ? 2.2 : 1)
                }
            }
            .onAppear { startBreathing() }
            .onChange(of: active) { _, _ in startBreathing() }
            .accessibilityLabel(active ? "Opponent is playing" : "Opponent is idle")
    }

    private func startBreathing() {
        breathe = false
        guard active else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            breathe = true
        }
    }
}

/// Activity dot + progress pips, re-evaluating "active" every couple of seconds
/// so the dot fades on its own when heartbeats stop.
struct OpponentPresenceRow: View {
    let presence: OpponentPresence
    var haptics = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            HStack(spacing: 8) {
                ActivityDot(active: presence.isActive(at: context.date))
                OpponentProgressDots(stepsDone: presence.stepsDone, solved: presence.hasSolved, haptics: haptics)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        OpponentPresenceRow(presence: OpponentPresence(cardsLeft: 5, lastActiveAt: .now))
        OpponentPresenceRow(presence: OpponentPresence(cardsLeft: 3, lastActiveAt: .now))
        OpponentPresenceRow(presence: OpponentPresence(cardsLeft: 2, lastActiveAt: .now.addingTimeInterval(-30)))
        OpponentPresenceRow(presence: OpponentPresence(cardsLeft: 1, hasSolved: true))
    }
    .padding()
    .background(Theme.background)
}

#if DEBUG
/// Debug-build hook: launch with `KRYPTO_DEMO_PRESENCE=1` to open the real
/// ranked match screen against a scripted opponent, so the presence row can be
/// watched in context (board, clock, intro) without a second device.
enum DemoPresence {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["KRYPTO_DEMO_PRESENCE"] == "1" }
}

/// Hosts the real `RankedMatchView` over a scripted match, and starts a fresh
/// one whenever the player leaves the result card.
struct DemoRankedHost: View {
    @ObservedObject private var ranked = RankedService.shared

    var body: some View {
        Group {
            if ranked.phase == .matched {
                RankedMatchView(ranked: ranked)
            } else {
                Color.clear
            }
        }
        .onAppear { ranked.startDemoMatch() }
        .onChange(of: ranked.phase) { _, phase in
            if phase == .idle { ranked.startDemoMatch() }
        }
    }
}

extension RankedService {
    /// Fakes a matched ranked game with no Firestore doc behind it. The
    /// opponent taps, combines, undoes, goes quiet, comes back and finally
    /// solves after about a minute unless the local player solves first.
    func startDemoMatch() {
        let (hand, target) = Krypto.deal()
        puzzle = (hand, target)
        opponentName = "maya_k"
        opponentElo = 1450
        opponent = OpponentState()
        winnerIsMe = nil
        isDemoMatch = true
        phase = .matched
        demoTask?.cancel()
        demoTask = Task { @MainActor [weak self] in
            // Seconds after launch, what the opponent does. `nil` cardsLeft keeps the
            // count; `beat` true sends a heartbeat (a tap), false is silence.
            let script: [(at: Double, cardsLeft: Int?, beat: Bool)] = [
                (4, nil, true), (6, nil, true), (8, 4, true), (10, nil, true),
                (13, 3, true), (15, nil, true), (18, 4, true), (20, nil, true),
                // quiet from 20s to 34s: the dot fades at ~28s
                (34, nil, true), (36, 3, true), (38, nil, true), (40, 2, true),
                (43, nil, true), (46, nil, true), (50, nil, true), (54, nil, true),
                (58, 1, false),
            ]
            let start = Date.now
            for step in script {
                let wait = step.at - Date.now.timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled, self.winnerIsMe == nil else { return }
                if let cardsLeft = step.cardsLeft { self.opponent.cardsLeft = cardsLeft }
                if step.beat { self.opponent.lastActiveAt = .now }
                if step.cardsLeft == 1 {
                    self.opponent.hasSolved = true
                    self.winnerIsMe = false
                }
            }
        }
    }
}
#endif
