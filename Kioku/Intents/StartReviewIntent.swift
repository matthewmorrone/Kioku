import AppIntents

// "Review with Kioku": opens the Learn tab on flashcards or multiple choice, where Start begins
// the session with the user's saved pool and options.
struct StartReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Review"
    static let description = IntentDescription("Opens flashcards or multiple choice to review your saved words.")
    static let openAppWhenRun = true

    @Parameter(title: "Mode", default: .flashcards)
    var mode: ReviewMode

    // Raises the request on the main actor, where ContentView performs it.
    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .startReview(mode.learnPage)
        return .result()
    }
}
