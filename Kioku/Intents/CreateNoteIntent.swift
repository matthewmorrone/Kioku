import AppIntents

// "New note" in Shortcuts and Siri: creates a note from dictated or shared text and opens it in Read.
struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Creates a new note with the given text and opens it.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", requestValueDialog: "What should the note say?")
    var text: String

    @Parameter(title: "Title")
    var noteTitle: String?

    // Raises the request on the main actor, where ContentView performs it.
    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw KiokuIntentError.emptyText }
        IntentRouter.shared.pending = .createNote(title: noteTitle ?? "", text: trimmed)
        return .result()
    }
}
