import UIKit
import UserNotifications

// App delegate whose sole job is to register the Word-of-the-Day notification deep-link handler at
// launch. UNUserNotificationCenter.delegate MUST be assigned before the app finishes launching:
// when a notification cold-launches the app (e.g. tapping the daily word on the watch after the
// process was terminated), iOS delivers the tap response during launch. If no delegate exists yet
// the response is dropped and the deep link silently fails. ContentView.onAppear ran too late for
// this — it fires after launch completes — so the handler now lives here instead.
final class AppDelegate: NSObject, UIApplicationDelegate {
    // Retains the handler for the process lifetime; UNUserNotificationCenter holds its delegate weakly.
    private var notificationHandler: NotificationDeepLinkHandler?

    // Wires the notification delegate as early as possible so cold-launch taps are delivered.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        WOTDDiag.reset()
        WOTDDiag.log("AppDelegate didFinishLaunching — registering notification handler")
        notificationHandler = NotificationDeepLinkHandler(navigation: .shared)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            WOTDDiag.log("authStatus=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) lockScreen=\(settings.lockScreenSetting.rawValue) notifCenter=\(settings.notificationCenterSetting.rawValue)")
        }
        return true
    }
}
