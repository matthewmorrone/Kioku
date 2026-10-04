import SwiftUI

// Renders Settings → Custom Words: the words the dictionary doesn't have on its own. Layout: a
// Learned section (spellings taught from the lookup sheet; tap to edit, swipe to delete) and a
// Built-In section (the entries extras.json adds to every dictionary build, read-only).
struct CustomWordsView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var learnedWordStore: LearnedWordStore
    @State private var builtInEntries: [DictionaryEntry] = []
    @State private var editingWord: LearnedWord?

    var body: some View {
        List {
            Section("Learned") {
                ForEach(learnedWordStore.words) { word in
                    Button {
                        editingWord = word
                    } label: {
                        row(title: word.spelling, detail: detail(for: word))
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        learnedWordStore.remove(id: learnedWordStore.words[index].id)
                    }
                }
            }
            Section("Built-In") {
                ForEach(builtInEntries, id: \.entryId) { entry in
                    row(
                        title: entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? entry.matchedSurface,
                        detail: [entry.kanjiForms.isEmpty ? nil : entry.kanaForms.first?.text, entry.senses.first?.glosses.first]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                }
            }
        }
        .sheet(item: $editingWord) { word in
            LearnSpellingView(
                surface: word.spelling,
                dictionaryStore: dictionaryStore,
                existing: word,
                onFinish: { editingWord = nil }
            )
        }
        .task { loadBuiltInEntries() }
    }

    // A word and, beneath it, what it stands for.
    private func row(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // "same as 駆け寄る" for a linked spelling, "reading · meaning" for a new word.
    private func detail(for word: LearnedWord) -> String {
        switch word.kind {
        case .newWord(let reading, let meaning):
            return "\(reading) · \(meaning)"
        case .spellingOf(let entSeq):
            let entry = dictionaryStore?.entryID(forEntSeq: entSeq).flatMap { try? dictionaryStore?.lookupEntry(entryID: $0) }
            let headword = entry.flatMap { $0.kanjiForms.first?.text ?? $0.kanaForms.first?.text }
            return headword.map { "same as \($0)" } ?? "same as a word missing from this dictionary"
        }
    }

    // Reads the extras.json entries from the dictionary; empty when no dictionary is loaded.
    private func loadBuiltInEntries() {
        guard let dictionaryStore else { return }
        do {
            builtInEntries = try dictionaryStore.fetchBuiltInCustomEntries()
        } catch {
            AppLog.error(.dictionary, "Custom Words: loading built-in entries failed: \(error)")
        }
    }
}
