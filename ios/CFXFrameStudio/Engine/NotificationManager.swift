import Foundation
import UserNotifications
import UIKit

/// Manages local notifications for CFX FrameStudio with full Lock Screen, Dynamic Island / Banner, and Sound support
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published var isAuthorized: Bool = false
    @Published var isLockScreenEnabled: Bool = true
    @Published var isSoundsEnabled: Bool = true
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
    }

    /// Configures the notification center delegate and refreshes authorization status
    func setup() {
        UNUserNotificationCenter.current().delegate = self
        checkAuthorizationStatus()
    }

    /// Queries the system for the current notification permission state including Lock Screen & Sound settings
    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.authorizationStatus = settings.authorizationStatus
                self?.isAuthorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                self?.isLockScreenEnabled = (settings.lockScreenSetting == .enabled)
                self?.isSoundsEnabled = (settings.soundSetting == .enabled)
            }
        }
    }

    /// Requests user authorization for Lock Screen alerts, Notification Center banners, and sounds
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        UNUserNotificationCenter.current().requestAuthorization(options: options) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                self?.checkAuthorizationStatus()
                completion?(granted)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Delivers notifications as a prominent banner and sound even when the app is currently active in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    /// Handles user tapping on a notification from the Lock Screen or Notification Center
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    // MARK: - Downloader Notification Triggers

    /// Posts a rich completion notification appearing on the Lock Screen, dynamic banner, and Notification Center
    func notifyDownloadCompleted(filename: String, savedToPhotos: Bool, fileSizeFormatted: String? = nil, delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "✓ Download Complete"
        
        let sizeText = (fileSizeFormatted != nil && !fileSizeFormatted!.isEmpty) ? " (\(fileSizeFormatted!))" : ""
        let storageDestination = savedToPhotos ? "Saved to Camera Roll & Files" : "Saved to CFX Files"
        content.body = "“\(filename)” finished downloading\(sizeText). \(storageDestination)."
        content.sound = .default

        // Use .active which lights up the Lock Screen and sounds immediately without requiring Apple's restricted time-sensitive entitlement
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        scheduleNotification(content: content, delay: delay)
    }

    /// Posts a failure notification alerting the user on the Lock Screen if a background download fails
    func notifyDownloadFailed(filename: String?, error: String, delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "✕ Download Failed"
        
        let fileText = (filename != nil && !filename!.isEmpty) ? " for “\(filename!)”" : ""
        content.body = "Download\(fileText) could not be completed: \(error)"
        content.sound = .default

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        scheduleNotification(content: content, delay: delay)
    }

    /// Posts a notification when a carousel / batch social download completes
    func notifyBatchDownloadCompleted(count: Int, platform: String, delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "✓ \(platform) Batch Complete"
        content.body = "All \(count) \(platform) items were downloaded and saved to your Camera Roll."
        content.sound = .default

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        scheduleNotification(content: content, delay: delay)
    }

    /// Helper to test Lock Screen delivery with a 4-second delay so the user can lock their phone
    func testLockScreenNotification(delaySeconds: TimeInterval = 4.0) {
        let content = UNMutableNotificationContent()
        content.title = "✓ Download Complete"
        content.body = "“Sample_Video.mp4” (42.5 MB) finished downloading. Saved to Camera Roll & Files."
        content.sound = .default

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        scheduleNotification(content: content, delay: delaySeconds)
    }

    private func scheduleNotification(content: UNNotificationContent, delay: TimeInterval?) {
        let trigger: UNNotificationTrigger?
        if let delay = delay, delay > 0 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        } else {
            // Immediate delivery: passing nil trigger is Apple's recommended way for immediate notification delivery
            trigger = nil
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager] Error posting notification: \(error.localizedDescription)")
            }
        }
    }
}
