import SwiftUI

/// Hard stop shown when Remote Config's `min_supported_build` is raised above
/// this build. It's the one lever that can retire an already-shipped binary —
/// a broken client can be pushed off the live services without waiting on
/// review — so it deliberately offers no way past it.
struct UpdateRequiredView: View {
    /// Optional console-supplied explanation; falls back to generic copy so a
    /// blank `update_message` still renders something coherent.
    let message: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Theme.accent)

                Text("Update Required")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkDark)

                Text(message.isEmpty
                     ? "This version of Krypto is no longer supported. Please update to keep playing."
                     : message)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = URL(string: AppLinks.appStore) {
                    Link(destination: url) {
                        Text("Update")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Theme.button, in: Capsule())
                    }
                }
            }
            .padding(32)
        }
    }
}

#Preview {
    UpdateRequiredView(message: "")
}
