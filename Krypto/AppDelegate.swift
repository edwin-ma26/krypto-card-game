import UIKit
import FirebaseMessaging

extension Notification.Name {
    static let fcmTokenRefreshed = Notification.Name("fcmTokenRefreshed")
}

/// SwiftUI's `App` protocol has no hook for APNs device-token delivery or
/// FCM token refresh, so those still need a classic `UIApplicationDelegate`,
/// wired in via `@UIApplicationDelegateAdaptor` in `KryptoApp`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        NotificationCenter.default.post(name: .fcmTokenRefreshed, object: fcmToken)
    }

    /// Show the banner even while the app is in the foreground — the default
    /// is to suppress it, which would make friend-request pushes silent for
    /// anyone actively playing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
