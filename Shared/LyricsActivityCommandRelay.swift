import Foundation

// Hands Live Activity button presses to the app's players. The intents behind the buttons are
// compiled into both the app and the widget extension, but a LiveActivityIntent runs in the app's
// process, where RemoteCommandRouter installs `handler`; in the extension it stays nil and a send
// is a no-op.
@MainActor
enum LyricsActivityCommandRelay {
    static var handler: ((LyricsActivityCommand) -> Void)?

    // Forwards a button press to whichever player the app's router picks.
    static func send(_ command: LyricsActivityCommand) {
        handler?(command)
    }
}
