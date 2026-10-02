import Foundation

// One sound at a time. The song player (AudioPlaybackController: the Read tab's song, and the
// breakdown's intro/outro) and the breakdown's listen-along narration (SongLiveListenController)
// announce when they start, and every other player pauses on hearing it — so a card's play button
// can't talk over the intro, and the breakdown can't start on top of a song playing in Read.
// Tap-to-hear (SpeechSynthesisHelper) is left out on purpose: it ducks the song under one word
// rather than stopping it.
enum ExclusivePlayback {
    static let didStart = Notification.Name("ExclusivePlayback.didStart")

    // Announces that `owner` has started playing, so every other player pauses.
    @MainActor static func claim(_ owner: AnyObject) {
        NotificationCenter.default.post(name: didStart, object: owner)
    }
}
