import AppIntents

// The lyrics Live Activity's play/pause button. A LiveActivityIntent, so it runs in the app's process
// (waking it if needed) without opening the app.
nonisolated struct LyricsTogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"

    // Relays the press to the app's player on the main actor, where the players live.
    @MainActor
    func perform() async throws -> some IntentResult {
        LyricsActivityCommandRelay.send(.togglePlayback)
        return .result()
    }
}
