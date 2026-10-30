import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        NotificationManager.shared.setup()
        _ = DirectDownloadEngine.shared
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == DirectDownloadEngine.backgroundSessionIdentifier {
            self.backgroundSessionCompletionHandler = completionHandler
            _ = DirectDownloadEngine.shared
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NotificationManager.shared.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NotificationManager.shared.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
}

@main
struct CFXFrameStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NotificationManager.shared.setup()
        #if DEBUG
        CFXEditorTests.shared.runAllTests()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LauncherView()
                .preferredColorScheme(.dark)
        }
    }
}
