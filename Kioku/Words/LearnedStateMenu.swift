import SwiftUI
import UIKit

// The shared three-option long-press menu for a word's star/save button: each option sets
// LearnedState directly (not a toggle — the star icon already shows the current mark). One
// definition so every star in the app (Words list, Word Detail, sentence-parse rows, dictionary
// search results, Read-tab segment list, and the Read-tab lookup popover/sheet) offers the
// identical Saved/Not Learned/Learned choices instead of drifting copies.
//
// Rendered as Toggle rather than Button so the currently-active option shows a checkmark inside
// the menu itself — SwiftUI renders a Toggle inside Menu/.contextMenu content as a checkable
// item automatically. The binding's `set` ignores whatever value SwiftUI would assign and always
// calls setState with this option's own state; only `get` (compared against currentState) matters.
@ViewBuilder
func learnedStateMenuButtons(currentState: LearnedState, isSaved: Bool, setState: @escaping (LearnedState) -> Void) -> some View {
    // Save is checked only for a saved word with no mark: an unsaved word has no state to show.
    Toggle(isOn: Binding(get: { isSaved && currentState == .unmarked }, set: { _ in setState(.unmarked) })) {
        LearnedStateStyle.menuLabel(for: .unmarked)
    }
    Toggle(isOn: Binding(get: { currentState == .notLearned }, set: { _ in setState(.notLearned) })) {
        LearnedStateStyle.menuLabel(for: .notLearned)
    }
    Toggle(isOn: Binding(get: { currentState == .learned }, set: { _ in setState(.learned) })) {
        LearnedStateStyle.menuLabel(for: .learned)
    }
}

// Applies the mark on the next runloop instead of synchronously inside a context-menu action —
// a synchronous write lands while UIKit is still tearing the menu down, so the resulting
// re-render queues behind that work and the glyph only flips a beat late. Deferring lets
// teardown finish first, then the icon updates immediately.
//
// `surface` lets setLearnedState create the card on the spot when the word isn't saved yet —
// Learned/Not-Learned/Save from this menu always mean saved, never a silent no-op.
func learnedStateSetter(
    entryID: Int64,
    wordsStore: WordsStore,
    surface: String,
    sourceNoteID: UUID? = nil,
    defaultSenseIDs: [Int64] = []
) -> (LearnedState) -> Void {
    { state in
        DispatchQueue.main.async {
            wordsStore.setLearnedState(
                state,
                for: entryID,
                ensureSavedWithSurface: surface,
                sourceNoteID: sourceNoteID,
                defaultSenseIDs: defaultSenseIDs
            )
        }
    }
}

// UIKit equivalent of learnedStateMenuButtons, for the Read-tab lookup popover/sheet. Attach via
// `button.menu = learnedStateUIMenu(currentState:setState:)` with
// `button.showsMenuAsPrimaryAction = false` so a plain tap still fires the button's normal
// touchUpInside action while touch-and-hold shows this menu. `.state = .on` is UIMenu's own
// checked-item indicator, the UIKit counterpart of the SwiftUI Toggle-in-Menu trick above.
func learnedStateUIMenu(currentState: LearnedState, isSaved: Bool, setState: @escaping (LearnedState) -> Void) -> UIMenu {
    UIMenu(children: [
        UIAction(
            title: "Saved",
            image: LearnedStateStyle.coloredMenuImage(for: .unmarked),
            state: isSaved && currentState == .unmarked ? .on : .off
        ) { _ in setState(.unmarked) },
        UIAction(
            title: "Not Learned",
            image: LearnedStateStyle.coloredMenuImage(for: .notLearned),
            state: currentState == .notLearned ? .on : .off
        ) { _ in setState(.notLearned) },
        UIAction(
            title: "Learned",
            image: LearnedStateStyle.coloredMenuImage(for: .learned),
            state: currentState == .learned ? .on : .off
        ) { _ in setState(.learned) },
    ])
}
