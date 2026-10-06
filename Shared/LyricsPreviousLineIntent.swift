import AppIntents

// The lyrics Live Activity's back-a-line button. A LiveActivityIntent, so it runs in the app's process
// (waking it if needed) without opening the app.
nonisolated struct LyricsPreviousLineIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Previous Line"

    // Relays the press to the app's player on the main actor, where the players live.
    @MainActor
    func perform() async throws -> some IntentResult {
        LyricsActivityCommandRelay.send(.previousLine)
        return .result()
    }
}
