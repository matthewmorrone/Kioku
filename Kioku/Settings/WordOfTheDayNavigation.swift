import Combine
import Foundation

// Observable routing state for Word of the Day deep links.
// ContentView observes pendingEntryID and navigates to the corresponding saved word when set.
@MainActor
final class WordOfTheDayNavigation: ObservableObject {
    @Published var pendingEntryID: Int64? = nil
}
