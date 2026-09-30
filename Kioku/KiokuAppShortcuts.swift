import AppIntents

// Registers Kioku's Siri phrases so they work without the user building a shortcut first.
nonisolated struct KiokuAppShortcuts: AppShortcutsProvider {
    // Starts a random note that has audio. No phrase begins with "play": Siri routes those to Music.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayRandomNoteIntent(),
            phrases: [
                "Sing with \(.applicationName)",
                "\(.applicationName) karaoke",
                "Start \(.applicationName) karaoke",
            ],
            shortTitle: "Play Random Song",
            systemImageName: "music.note"
        )
    }
}
