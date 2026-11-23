import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct KryptoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var remote = Remote.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if remote.requiresUpdate {
                    UpdateRequiredView(message: remote.flags.updateMessage)
                } else {
                    HomeView()
                }
                #if DEBUG
                if DemoPresence.isEnabled {
                    DemoRankedHost()
                }
                #endif
                if !isReady {
                    LoadingView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isReady)
            .preferredColorScheme(.light)
            .onOpenURL { url in
                // Google Sign-In's round trip back into the app.
                _ = GIDSignIn.sharedInstance.handle(url)
            }
            .task {
                // Fetch alongside the splash rather than after it. The splash
                // isn't held open until the fetch lands, though — Firebase
                // persists the last activated payload and `Remote.init` applies
                // it, so from the second launch onward the first paint is
                // already correctly styled and a slow network can't stall the
                // launch. Only a first-ever install can briefly show the
                // shipped defaults before the fetch swaps them in.
                async let config: Void = remote.refresh()
                try? await Task.sleep(nanoseconds: 600_000_000)
                isReady = true
                await config
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up console changes on resume. Newly rendered views adopt
                // them; anything already on screen keeps its current styling
                // until it redraws, which avoids restyling mid-race.
                guard phase == .active, isReady else { return }
                Task { await remote.refresh() }
            }
        }
    }
}
