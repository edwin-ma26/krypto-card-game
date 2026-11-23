import SwiftUI

/// Branded splash shown briefly on cold launch while the app spins up.
struct LoadingView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("KryptoLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                ProgressView()
                    .tint(Theme.inkMuted)
            }
        }
    }
}

#Preview {
    LoadingView()
}
