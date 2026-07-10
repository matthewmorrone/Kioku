import SwiftUI

// The Learn tab's Coverage page: a list of notes that have saved words; picking one pushes the
// per-note learning-coverage breakdown. Owns its own NavigationStack like the sibling Learn pages.
struct CoverageView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore

    // Only notes that currently have at least one saved word — the same rule the Words-tab filter
    // uses (WordsFilterView.notesWithSavedWords).
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notesWithSavedWords.isEmpty {
                    ContentUnavailableView(
                        "No notes with saved words",
                        systemImage: "chart.bar.doc.horizontal"
                    )
                } else {
                    List(notesWithSavedWords) { note in
                        NavigationLink {
                            CoverageDetailView(note: note, dictionaryStore: dictionaryStore)
                        } label: {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Coverage", systemImage: "chart.bar.doc.horizontal")
            }
        }
    }
}
