import SwiftUI
import UIKit

// The shared three-option long-press menu for a word's star/save button: each option sets
// LearnedState directly (not a toggle — the star icon already shows the current mark). One
// definition so every star in the app (Words list, Word Detail, sentence-parse rows, dictionary
// search results, Read-tab segment list, and the Read-tab lookup popover/sheet) offers the
// identical Favorite/Learned/Not Learned choices instead of drifting copies.
@ViewBuilder
func learnedStateMenuButtons(setState: @escaping (LearnedState) -> Void) -> some View {
    Button { setState(.unmarked) } label: {
        Label("Favorite", systemImage: "star")
    }
    Button { setState(.learned) } label: {
        Label("Learned", systemImage: "checkmark")
    }
    Button { setState(.notLearned) } label: {
        Label("Not Learned", systemImage: "questionmark")
    }
}

// Applies the mark on the next runloop instead of synchronously inside a context-menu action —
// a synchronous write lands while UIKit is still tearing the menu down, so the resulting
// re-render queues behind that work and the glyph only flips a beat late. Deferring lets
// teardown finish first, then the icon updates immediately.
func learnedStateSetter(entryID: Int64, reviewStore: ReviewStore) -> (LearnedState) -> Void {
    { state in DispatchQueue.main.async { reviewStore.setLearnedState(state, for: entryID) } }
}

// UIKit equivalent of learnedStateMenuButtons, for the Read-tab lookup popover/sheet. Attach via
// `button.menu = learnedStateUIMenu(setState:)` with `button.showsMenuAsPrimaryAction = false` so
// a plain tap still fires the button's normal touchUpInside action while touch-and-hold shows
// this menu.
func learnedStateUIMenu(setState: @escaping (LearnedState) -> Void) -> UIMenu {
    UIMenu(children: [
        UIAction(title: "Favorite", image: UIImage(systemName: "star")) { _ in setState(.unmarked) },
        UIAction(title: "Learned", image: UIImage(systemName: "checkmark")) { _ in setState(.learned) },
        UIAction(title: "Not Learned", image: UIImage(systemName: "questionmark")) { _ in setState(.notLearned) },
    ])
}
