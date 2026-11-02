import SwiftUI

// The Data section's "Export for Anki" row, beside the app-wide Export and Import.
extension SettingsView {
    // Shares every saved word as an Anki-importable text file. Disabled until the dictionary is
    // ready (meanings come from it) and while there are no saved words.
    @ViewBuilder
    var ankiExportRow: some View {
        let words = wordsStore.words
        HStack {
            if let dictionaryStore, words.isEmpty == false {
                ShareLink(
                    item: AnkiExport(
                        words: words,
                        store: dictionaryStore,
                        listNamesByID: Dictionary(uniqueKeysWithValues: wordListsStore.lists.map { ($0.id, $0.name) })
                    ),
                    preview: SharePreview("Kioku words for Anki")
                ) {
                    Label("Export for Anki", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.borderless)
            } else {
                Label("Export for Anki", systemImage: "rectangle.stack.badge.plus")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            InfoButton(text: "Save all your saved words as a text file Anki can import, with readings, meanings, notes and list names as tags.")
        }
    }
}
