import SwiftUI

/// The small, tappable Founding Pup badge shown beside a player's name.
///
/// Rendered at inline sizes the full illustration turns to mush, so this draws
/// a simplified mark — gold ring, paw silhouette — and saves the actual dog for
/// the detail sheet, where it has room to read.
struct BadgeMark: View {
    var size: CGFloat = 26
    var stage: BadgeStage = .pup
    /// Own badge only: adds the "refer one more" nudge to the detail sheet.
    var showsNextHint: Bool = false

    @State private var isShowingDetail = false

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: stage.ringColors,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .fill(stage.isCosmic ? Color(red: 0.12, green: 0.10, blue: 0.22) : Color(red: 0.99, green: 0.97, blue: 0.93))
                    .padding(size * 0.11)
                Image(systemName: stage.isCosmic ? "sparkles" : "pawprint.fill")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(stage.isCosmic ? Color(red: 0.85, green: 0.80, blue: 1.0) : stage.furDark)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        // Small marks are easy to miss and hard to hit; label it for VoiceOver
        // and give it a finger-sized target without changing the layout.
        .contentShape(Rectangle())
        .accessibilityLabel("\(stage.title) badge")
        .accessibilityHint("Shows what this badge means")
        .sheet(isPresented: $isShowingDetail) {
            BadgeDetailView(stage: stage, showsNextHint: showsNextHint)
        }
    }
}

/// The short "what is this?" popup, shown when anyone taps a badge — their own
/// or someone else's.
struct BadgeDetailView: View {
    var stage: BadgeStage = .pup
    var showsNextHint: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            DogBadge(size: 120, isRevealed: true, stage: stage)
                .padding(.top, 24)

            Text(stage.title)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)

            Text(stage.blurb)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            if showsNextHint, let hint = stage.nextHint {
                Label(hint, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Done") { dismiss() }
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .presentationDetents([.height(showsNextHint ? 440 : 400)])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    BadgeDetailView(stage: .cosmic, showsNextHint: true)
}
