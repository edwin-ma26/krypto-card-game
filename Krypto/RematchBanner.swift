import SwiftUI

/// The white notification card shared by every top-anchored alert banner
/// (friend challenge, friend request, rematch request). The whole surface
/// taps through to `onTap`, like a system notification; the trailing button
/// dismisses without also firing the tap.
struct AlertBannerCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var hasFoundingPup = false
    var badgeStage: BadgeStage = .pup
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkDark)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            if hasFoundingPup {
                BadgeMark(size: 20, stage: badgeStage)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "X wants a rematch" for a ranked opponent, shown once the player has left
/// the result card (which carries its own Accept/Decline row) — on Home, in
/// Single Player, Daily, the Multiplayer hub and the Competition hub alike,
/// since `RankedService.shared` keeps listening to the finished match for a
/// while after it's closed. Tap accepts; the x declines so the opponent's
/// "Waiting…" card updates instead of running out its timeout.
struct RankedRematchBanner: View {
    @ObservedObject var ranked = RankedService.shared
    /// Accept was tapped. The caller gets the player to the Competition
    /// screen, where the searching popup and the new match take over.
    var onAccept: () -> Void

    var body: some View {
        if ranked.hasIncomingRematchBanner {
            AlertBannerCard(
                icon: "arrow.counterclockwise",
                title: "\(ranked.opponentName ?? "Your opponent") wants a rematch",
                subtitle: "Tap to accept and play again",
                onTap: {
                    ranked.acceptRematch()
                    onAccept()
                },
                onDismiss: { ranked.declineRematch() }
            )
        }
    }
}
