import AppIntents

// The review activities Shortcuts can start. An AppEnum so Siri can take the choice inside a spoken
// phrase; each case maps onto the Learn page that runs it.
nonisolated enum ReviewMode: String, AppEnum {
    case flashcards
    case multipleChoice

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Review Mode")
    static let caseDisplayRepresentations: [ReviewMode: DisplayRepresentation] = [
        .flashcards: DisplayRepresentation(title: "Flashcards"),
        .multipleChoice: DisplayRepresentation(title: "Multiple Choice"),
    ]

    // The Learn page that hosts this activity.
    var learnPage: LearnPage {
        switch self {
        case .flashcards: return .flashcards
        case .multipleChoice: return .multipleChoice
        }
    }
}
