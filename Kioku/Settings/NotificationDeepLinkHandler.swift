import Foundation
import UserNotifications

// UNUserNotificationCenterDelegate that handles Word of the Day notification taps.
// Extracts the canonicalEntryID and surface from the notification payload and publishes them via WordOfTheDayNavigation.
final class NotificationDeepLinkHandler: NSObject, UNUserNotificationCenterDelegate {
    private let navigation: WordOfTheDayNavigation

    // Registers itself as the notification center delegate on init so taps are received app-wide.
    init(navigation: WordOfTheDayNavigation) {
        self.navigation = navigation
        super.init()
        UNUserNotificationCenter.current().delegate = self
        WOTDDiag.log("handler init — delegate assigned")
    }

    // Shows a banner and plays sound even when the app is already in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        WOTDDiag.log("willPresent (foreground delivery) id=\(notification.request.identifier)")
        completionHandler([.banner, .sound])
    }

    // Publishes the tapped notification's entry ID so ContentView can navigate to the word detail.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        WOTDDiag.log("didReceive ENTER action=\(response.actionIdentifier) id=\(response.notification.request.identifier)")
        let userInfo = response.notification.request.content.userInfo
        let rawID = userInfo["wordID"] as? String
        guard let idStr = rawID, let entryID = Int64(idStr) else {
            WOTDDiag.log("didReceive FAILED to parse wordID rawID=\(rawID ?? "nil")")
            return
        }
        let surface = userInfo["surface"] as? String
        WOTDDiag.log("didReceive entryID=\(entryID) hasSurface=\(surface != nil)")
        Task { @MainActor [navigation] in
            navigation.pendingTarget = WordOfTheDayTarget(entryID: entryID, surface: surface)
        }
    }
}
