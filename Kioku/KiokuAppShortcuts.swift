import AppIntents

// Registers Kioku's Siri phrases so they work without the user building a shortcut first.
nonisolated struct KiokuAppShortcuts: AppShortcutsProvider {
    // Karaoke, new note, review, word lookup and image lookup. No phrase begins with "play": Siri
    // routes those to Music.
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
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: StartReviewIntent(),
            phrases: [
                "Review with \(.applicationName)",
                "Study with \(.applicationName)",
                "Start \(\.$mode) in \(.applicationName)",
            ],
            shortTitle: "Start Review",
            systemImageName: "rectangle.on.rectangle.angled"
        )
        AppShortcut(
            intent: LookUpWordIntent(),
            phrases: [
                "Look up a word in \(.applicationName)",
                "\(.applicationName) dictionary",
            ],
            shortTitle: "Look Up Word",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: LookUpTextInImageIntent(),
            phrases: [
                "Look up text in an image with \(.applicationName)",
                "Read an image with \(.applicationName)",
            ],
            shortTitle: "Look Up Text in Image",
            systemImageName: "text.viewfinder"
        )
    }
}
