import Foundation

// One sound at a time. The song player (AudioPlaybackController: the Read tab's song, and the
// breakdown's intro/outro) and the breakdown's listen-along narration (SongLiveListenController)
// announce when they start, and every other player pauses on hearing it — so a card's play button
// can't talk over the intro, and the breakdown can't start on top of a song playing in Read.
// Tap-to-hear (SpeechSynthesisHelper) is left out on purpose: it ducks the song under one word
// rather than stopping it.
enum ExclusivePlayback {
    static let didStart = Notification.Name("ExclusivePlayback.didStart")

    // The player that started most recently: the one the lock-screen buttons drive
    // (RemoteCommandRouter). Weak so a dismissed screen's player isn't kept alive by it.
    @MainActor private(set) static weak var current: AnyObject?

    // Announces that `owner` has started playing, so every other player pauses.
    @MainActor static func claim(_ owner: AnyObject) {
        current = owner
        NotificationCenter.default.post(name: didStart, object: owner)
    }
}
