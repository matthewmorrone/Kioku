import SwiftUI

// The Words screen's "Export for Anki" action, kept apart from the overflow menu it appears in.
extension WordsView {
    // A share-sheet entry for the words currently listed (so a list or note filter exports just
    // that list or note). Absent until the dictionary is ready, since the meanings come from it.
    @ViewBuilder
    var ankiExportLink: some View {
        let words = visibleWords
        if let dictionaryStore, words.isEmpty == false {
            ShareLink(
                item: AnkiExport(
                    words: words,
                    store: dictionaryStore,
                    listNamesByID: Dictionary(uniqueKeysWithValues: wordListsStore.lists.map { ($0.id, $0.name) })
                ),
                preview: SharePreview("Kioku words for Anki")
            ) {
                Label("Export for Anki", systemImage: "square.and.arrow.up")
            }
        }
    }
}
