import SwiftUI

/// First-launch walkthrough. Four short, animated panels that explain the core
/// loop — combine number cards to hit the target — and call out the hint button,
/// then drop the player straight into Single Player to try it. Shown once, gated
/// by `hasCompletedOnboarding` in `HomeView`.
struct OnboardingView: View {
    /// Marks onboarding done and launches Single Player.
    var onTryItOut: () -> Void
    /// Marks onboarding done and returns to Home.
    var onSkip: () -> Void

    @State private var step = 0
    private let lastStep = 3

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if step < lastStep {
                        Button("Skip", action: onSkip)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 24)
                .padding(.top, 16)

                TabView(selection: $step) {
                    WelcomePanel().tag(0)
                    TargetPanel().tag(1)
                    CombinePanel().tag(2)
                    HintPanel().tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)

                HStack(spacing: 8) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Theme.accent : Theme.inkMuted.opacity(0.25))
                            .frame(width: i == step ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(duration: 0.3), value: step)
                .padding(.bottom, 20)

                Button {
                    if step < lastStep {
                        withAnimation { step += 1 }
                    } else {
                        onTryItOut()
                    }
                } label: {
                    Text(step < lastStep ? "Next" : "Try it out")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Shared pieces

/// A single number card, sized down for the walkthrough visuals but styled to
/// match `CardView` on the real board.
private struct MiniCard: View {
    let text: String
    var colorIndex = 0
    var size: CGFloat = 58

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.inkDark)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(width: size, height: size * 1.32)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.cardColors[colorIndex % max(Theme.cardColors.count, 1)])
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            )
    }
}

/// Common panel layout: a fixed-height animated visual over a title and blurb.
private struct PanelScaffold<Visual: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var visual: Visual

    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            visual
                .frame(height: 190)
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 34)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Panels

private struct WelcomePanel: View {
    @State private var animate = false
    private let fan: [(String, Int)] = [("3", 0), ("8", 2), ("5", 4)]

    var body: some View {
        PanelScaffold(
            title: "Welcome to Krypto!",
            subtitle: "Combine number cards with +, −, ×, and ÷ to hit the target number."
        ) {
            ZStack {
                ForEach(Array(fan.enumerated()), id: \.offset) { idx, card in
                    MiniCard(text: card.0, colorIndex: card.1)
                        .rotationEffect(.degrees(animate ? Double(idx - 1) * 12 : 0))
                        .offset(
                            x: animate ? CGFloat(idx - 1) * 48 : 0,
                            y: animate ? -6 : 44
                        )
                        .opacity(animate ? 1 : 0)
                }
                Image("KryptoLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .scaleEffect(animate ? 1 : 0.5)
                    .opacity(animate ? 1 : 0)
                    .offset(y: -8)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.35)) { animate = true }
        }
    }
}

private struct TargetPanel: View {
    @State private var animate = false
    private let hand: [(String, Int)] = [("3", 0), ("8", 1), ("5", 2), ("2", 3), ("7", 4)]

    var body: some View {
        PanelScaffold(
            title: "Hit the target",
            subtitle: "You're dealt five number cards and one target. You must use all five — combine them down to a single card that equals the target exactly."
        ) {
            VStack(spacing: 22) {
                Text("24")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.inkDark)
                    .frame(width: 116, height: 74)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    )
                    .scaleEffect(animate ? 1 : 0.7)
                    .opacity(animate ? 1 : 0)

                HStack(spacing: 8) {
                    ForEach(Array(hand.enumerated()), id: \.offset) { idx, card in
                        MiniCard(text: card.0, colorIndex: card.1, size: 46)
                            .offset(y: animate ? 0 : 28)
                            .opacity(animate ? 1 : 0)
                            .animation(
                                .spring(duration: 0.5).delay(0.12 + Double(idx) * 0.08),
                                value: animate
                            )
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6)) { animate = true }
        }
    }
}

private struct CombinePanel: View {
    @State private var merged = false

    var body: some View {
        PanelScaffold(
            title: "Combine two at a time",
            subtitle: "Tap a card, tap an operation, then tap another card. The two merge into one — keep going until a single card is left."
        ) {
            ZStack {
                HStack(spacing: 14) {
                    MiniCard(text: "3", colorIndex: 0)
                    Text("×")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.inkMuted)
                    MiniCard(text: "8", colorIndex: 2)
                }
                .opacity(merged ? 0 : 1)
                .scaleEffect(merged ? 0.8 : 1)

                MiniCard(text: "24", colorIndex: 4)
                    .opacity(merged ? 1 : 0)
                    .scaleEffect(merged ? 1 : 0.55)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.spring(duration: 0.55, bounce: 0.3)) { merged = true }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeInOut(duration: 0.4)) { merged = false }
            }
        }
    }
}

private struct HintPanel: View {
    @State private var pulse = false

    var body: some View {
        PanelScaffold(
            title: "Stuck? Tap the hint",
            subtitle: "The light bulb in the top bar suggests one valid next move — a nudge, never the whole solution."
        ) {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.45), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pulse ? 1.9 : 1)
                    .opacity(pulse ? 0 : 0.9)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(16)
                    .background(Theme.pill, in: Circle())
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

#Preview {
    OnboardingView(onTryItOut: {}, onSkip: {})
}
