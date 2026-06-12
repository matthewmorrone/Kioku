import Combine
import Foundation

// A deep-link target carrying both the canonical entry ID and the surface that the notification
// was built from. Surface matters: WordsView.detailWord can synthesize a detail target directly
// from a surface hint, so threading it through means the detail view resolves even before the
// dictionary store has finished loading and even if the word is no longer in the saved set.
struct WordOfTheDayTarget: Equatable {
    let entryID: Int64
    let surface: String?
}

// Observable routing state for Word of the Day deep links.
// ContentView observes pendingTarget and navigates to the corresponding saved word when set.
@MainActor
final class WordOfTheDayNavigation: ObservableObject {
    // Shared so the AppDelegate can wire the notification handler at launch while ContentView
    // observes the same instance — both must point at one object for the deep link to land.
    static let shared = WordOfTheDayNavigation()

    @Published var pendingTarget: WordOfTheDayTarget? = nil
}
