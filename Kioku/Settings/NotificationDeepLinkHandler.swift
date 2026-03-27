import Foundation
import UserNotifications

// UNUserNotificationCenterDelegate that handles Word of the Day notification taps.
// Extracts the canonicalEntryID from the notification payload and publishes it via WordOfTheDayNavigation.
final class NotificationDeepLinkHandler: NSObject, UNUserNotificationCenterDelegate {
    private let navigation: WordOfTheDayNavigation

    // Registers itself as the notification center delegate on init so taps are received app-wide.
    init(navigation: WordOfTheDayNavigation) {
        self.navigation = navigation
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // Shows a banner and plays sound even when the app is already in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Publishes the tapped notification's entry ID so ContentView can navigate to the word detail.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let idStr = userInfo["wordID"] as? String, let entryID = Int64(idStr) else { return }
        Task { @MainActor [navigation] in
            navigation.pendingEntryID = entryID
        }
    }
}
