import AppIntents

// "Look up a word": opens the Words tab with the word already searched.
struct LookUpWordIntent: AppIntent {
    static let title: LocalizedStringResource = "Look Up Word"
    static let description = IntentDescription("Searches the dictionary for a Japanese or English word.")
    static let openAppWhenRun = true

    @Parameter(title: "Word", requestValueDialog: "Which word do you want to look up?")
    var word: String

    // Raises the request on the main actor, where ContentView performs it.
    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw KiokuIntentError.emptyText }
        IntentRouter.shared.pending = .lookUp(trimmed)
        return .result()
    }
}
