import SwiftUI

/// Plain-language rules, reachable from Home so a first-time player doesn't
/// have to guess how the cards combine before their first puzzle.
struct HowToPlayView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Rule: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let rules: [Rule] = [
        Rule(
            icon: "target",
            title: "Hit the target",
            body: "You're dealt five number cards and a target number. You must use all five, combining them with +, −, ×, and ÷ down to a single card that equals the target exactly."
        ),
        Rule(
            icon: "hand.tap.fill",
            title: "Combine two cards at a time",
            body: "Tap a card, tap an operation, then tap a second card. The two cards merge into the result, which becomes a new card you can use again."
        ),
        Rule(
            icon: "arrow.uturn.backward",
            title: "Undo anytime",
            body: "Made a move you didn't mean to? Undo steps back through your combinations one at a time."
        ),
        Rule(
            icon: "lightbulb.fill",
            title: "Stuck? Use a hint",
            body: "A hint suggests one valid next combination without giving away the whole solution."
        ),
        Rule(
            icon: "bolt.fill",
            title: "Racing a friend",
            body: "In Multiplayer, everyone gets the same hand and target. Buzz \"Krypto!\" the moment you think you've solved it — you then have a short window to prove your solution before the floor opens back up."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(rules) { rule in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: rule.icon)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.title)
                                    .font(.system(.headline, design: .rounded, weight: .heavy))
                                    .foregroundStyle(Theme.inkDark)
                                Text(rule.body)
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("How to Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
    }
}

#Preview {
    HowToPlayView()
}
