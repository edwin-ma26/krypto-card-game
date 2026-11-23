import SwiftUI

/// Dismissible "new version available" nudge, shown from `HomeView` when Remote
/// Config's `latest_recommended_build` is above this build — but not above
/// `min_supported_build`, which routes to the non-dismissible
/// `UpdateRequiredView` instead. Nags at most once per recommended build,
/// tracked by `lastDismissedUpdateBuild` in `HomeView`.
struct SoftUpdateView: View {
    /// Optional console-supplied copy; falls back to generic text when blank.
    let message: String
    var onUpdate: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.accent)

            Text("Update Available")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)

            Text(message.isEmpty
                 ? "A newer version of Krypto is out, with the latest fixes and features."
                 : message)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(action: onUpdate) {
                    Text("Update")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 16))
                }
                Button(action: onLater) {
                    Text("Later")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.top, 4)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Theme.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        SoftUpdateView(message: "", onUpdate: {}, onLater: {})
    }
}
