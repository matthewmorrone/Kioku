import AppIntents

// The "Sing with Kioku" Siri / Shortcuts action: opens the app and plays a random note that has an
// audio attachment. The note is picked in the app (ContentView owns NotesStore), so this intent
// only raises the request on ReadNoteNavigation and lets the app shell route it.
nonisolated struct PlayRandomNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Random Song"
    static let description = IntentDescription("Opens a random note with audio and starts playing it.")
    static let openAppWhenRun = true

    // Publishes the playback request on the main actor, where ContentView observes it.
    @MainActor
    func perform() async throws -> some IntentResult {
        ReadNoteNavigation.shared.isRandomPlaybackRequested = true
        return .result()
    }
}
