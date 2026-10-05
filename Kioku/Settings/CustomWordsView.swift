import SwiftUI
import UniformTypeIdentifiers

// Renders Settings → Custom Words: the words added to the dictionary on this device, starting from
// the defaults in extras.json. Layout: one list of words (tap to edit, swipe to delete); a toolbar
// with Add and a menu for Export extras.json, Import extras.json and Restore Defaults. The editor
// opens as a sheet; import asks before replacing the list.
struct CustomWordsView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var customWordStore: CustomWordStore
    @State private var editingWord: CustomWord?
    @State private var isAddingWord = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var pendingImport: [CustomWord]?
    @State private var importError: String?

    var body: some View {
        List {
            ForEach(customWordStore.words) { word in
                Button {
                    editingWord = word
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CustomWordIdentity.headword(of: word)).foregroundStyle(.primary)
                        Text(detail(for: word))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    customWordStore.remove(id: customWordStore.words[index].id)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export extras.json") { isExporting = true }
                    Button("Import extras.json") { isImporting = true }
                    Button("Restore Defaults") { customWordStore.restoreDefaults() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingWord = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Word")
            }
        }
        .sheet(item: $editingWord) { word in
            CustomWordEditorView(existing: word, dictionaryStore: dictionaryStore) { editingWord = nil }
        }
        .sheet(isPresented: $isAddingWord) {
            CustomWordEditorView(existing: nil, dictionaryStore: dictionaryStore) { isAddingWord = false }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: ExtrasJSONDocument(words: customWordStore.words),
            contentType: .json,
            defaultFilename: "extras.json"
        ) { result in
            if case .failure(let error) = result {
                AppLog.error(.dictionary, "Custom Words export failed: \(error)")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            readImport(result)
        }
        .alert(
            "Replace Custom Words?",
            isPresented: Binding(get: { pendingImport != nil }, set: { if $0 == false { pendingImport = nil } })
        ) {
            Button("Replace", role: .destructive) {
                if let pendingImport { customWordStore.replaceWords(with: pendingImport) }
                pendingImport = nil
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The list will be replaced by the \(pendingImport?.count ?? 0) words in the file.")
        }
        .alert(
            "Import Failed",
            isPresented: Binding(get: { importError != nil }, set: { if $0 == false { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // "same as 駆け寄る" for extra spellings, "reading · first gloss" for a word of its own.
    private func detail(for word: CustomWord) -> String {
        if let sameAs = word.sameAsEntSeq {
            let entry = dictionaryStore?.entryID(forEntSeq: sameAs).flatMap { try? dictionaryStore?.lookupEntry(entryID: $0) }
            let headword = entry.flatMap { $0.kanjiForms.first?.text ?? $0.kanaForms.first?.text }
            return headword.map { "same as \($0)" } ?? "same as a word missing from this dictionary"
        }
        let reading = word.kanji.isEmpty ? nil : word.kana.first
        return [reading, word.senses.first?.glosses.first].compactMap { $0 }.joined(separator: " · ")
    }

    // Reads a picked extras.json and asks before replacing the list; unreadable files say why.
    private func readImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try CustomWordsExtrasCodec.decode(Data(contentsOf: url))
        } catch {
            importError = error.localizedDescription
        }
    }
}
