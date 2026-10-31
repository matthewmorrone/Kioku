import Combine
import Foundation

// The hand-off point between App Intents and the app shell, in the same spirit as ReadNoteNavigation:
// an intent can run before ContentView exists, so it leaves its request here and ContentView
// consumes it on appear and whenever it changes.
@MainActor
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()

    @Published var pending: IntentRequest? = nil

    // Takes the pending request, clearing it so it is performed once.
    func consume() -> IntentRequest? {
        defer { pending = nil }
        return pending
    }
}
