import CoreSpotlight
import SwiftUI

// Attaches the Spotlight behaviour to ContentView as one modifier — a sync whenever the notes,
// the saved words, or the dictionary's readiness change, and routing of a tapped result — so
// ContentView's already long modifier chain stays within what the type-checker can resolve.
struct SpotlightHooks: ViewModifier {
    let notes: [Note]
    let words: [SavedWord]
    let dictionaryReady: Bool
    let sync: () -> Void
    // Receives the raw identifier of the result the user tapped.
    let open: (String) -> Void

    // Wraps the content with the three sync triggers and the result-tap handler.
    func body(content: Content) -> some View {
        content
            .onChange(of: notes) { _, _ in sync() }
            .onChange(of: words) { _, _ in sync() }
            .onChange(of: dictionaryReady) { _, _ in sync() }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                open(raw)
            }
    }
}
