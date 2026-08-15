import SwiftUI
import UIKit

// The shared three-option long-press menu for a word's star/save button: each option sets
// LearnedState directly (not a toggle — the star icon already shows the current mark). One
// definition so every star in the app (Words list, Word Detail, sentence-parse rows, dictionary
// search results, Read-tab segment list, and the Read-tab lookup popover/sheet) offers the
// identical Favorite/Learned/Not Learned choices instead of drifting copies.
//
// Rendered as Toggle rather than Button so the currently-active option shows a checkmark inside
// the menu itself — SwiftUI renders a Toggle inside Menu/.contextMenu content as a checkable
// item automatically. The binding's `set` ignores whatever value SwiftUI would assign and always
// calls setState with this option's own state; only `get` (compared against currentState) matters.
@ViewBuilder
func learnedStateMenuButtons(currentState: LearnedState, setState: @escaping (LearnedState) -> Void) -> some View {
    Toggle(isOn: Binding(get: { currentState == .unmarked }, set: { _ in setState(.unmarked) })) {
        Label("Favorite", systemImage: "star")
    }
    Toggle(isOn: Binding(get: { currentState == .learned }, set: { _ in setState(.learned) })) {
        Label("Learned", systemImage: "checkmark")
    }
    Toggle(isOn: Binding(get: { currentState == .notLearned }, set: { _ in setState(.notLearned) })) {
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
// `button.menu = learnedStateUIMenu(currentState:setState:)` with
// `button.showsMenuAsPrimaryAction = false` so a plain tap still fires the button's normal
// touchUpInside action while touch-and-hold shows this menu. `.state = .on` is UIMenu's own
// checked-item indicator, the UIKit counterpart of the SwiftUI Toggle-in-Menu trick above.
func learnedStateUIMenu(currentState: LearnedState, setState: @escaping (LearnedState) -> Void) -> UIMenu {
    UIMenu(children: [
        UIAction(title: "Favorite", image: UIImage(systemName: "star"), state: currentState == .unmarked ? .on : .off) { _ in setState(.unmarked) },
        UIAction(title: "Learned", image: UIImage(systemName: "checkmark"), state: currentState == .learned ? .on : .off) { _ in setState(.learned) },
        UIAction(title: "Not Learned", image: UIImage(systemName: "questionmark"), state: currentState == .notLearned ? .on : .off) { _ in setState(.notLearned) },
    ])
}
