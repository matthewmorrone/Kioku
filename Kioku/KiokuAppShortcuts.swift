import AppIntents

// Registers Kioku's Siri phrases so they work without the user building a shortcut first.
nonisolated struct KiokuAppShortcuts: AppShortcutsProvider {
    // "Play Kioku" and variants start a random note that has audio.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayRandomNoteIntent(),
            phrases: [
                "Play \(.applicationName)",
                "Play a song in \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play Random Song",
            systemImageName: "music.note"
        )
    }
}
