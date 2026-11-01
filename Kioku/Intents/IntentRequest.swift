import Foundation

// A request an App Intent hands to the running app. Intents only raise one of these on IntentRouter;
// ContentView owns the stores and performs it. Pure data.
enum IntentRequest: Equatable {
    // Creates a note with this text and opens it in Read.
    case createNote(title: String, text: String)
    // Opens the Learn tab on the page for this activity.
    case startReview(LearnPage)
    // Opens the Words tab searching for this text.
    case lookUp(String)
}
