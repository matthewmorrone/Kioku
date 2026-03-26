import SwiftUI
import UniformTypeIdentifiers

// Controls which word list mode is selected during import.
enum CSVImportListMode: Hashable {
    case none
    case existing
    case new
}

// Renders the CSV import sheet: file picker, paste editor, list assignment, preview, and import action.
// Major sections: input controls, list assignment picker, text editor, parsed preview, import button.
struct CSVImportView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore

    @Environment(\.dismiss) private var dismiss
    @State private var rawText: String = ""
    @FocusState private var isEditorFocused: Bool
    @State private var isParsing: Bool = false
    @State private var items: [CSVImportItem] = []
    @State private var errorText: String? = nil
    @State private var isFileImporterPresented: Bool = false
    @State private var addToListMode: CSVImportListMode = .none
    @State private var selectedExistingListID: UUID? = nil
    @State private var newListName: String = ""

    private var importableItems: [CSVImportItem] {
        items.filter(\.isImportable)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                inputControls
                listControls
                csvEditor
                previewList
                importButton
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                isEditorFocused = false
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide Keyboard") { isEditorFocused = false }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
                allowsMultipleSelection: false,
                onCompletion: handleFileImport
            )
        }
    }

    // MARK: - Sections

    private var inputControls: some View {
        HStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Choose File", systemImage: "doc")
            }

            Spacer()

            Button {
                Task { await parse() }
            } label: {
                if isParsing {
                    ProgressView()
                } else {
                    Text("Parse")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isParsing || rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var listControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add imported words to")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("List mode", selection: $addToListMode) {
                Text("No list").tag(CSVImportListMode.none)
                Text("Existing list").tag(CSVImportListMode.existing)
                Text("New list").tag(CSVImportListMode.new)
            }
            .pickerStyle(.segmented)

            switch addToListMode {
            case .none:
                EmptyView()
            case .existing:
                if wordListsStore.lists.isEmpty {
                    Text("No lists yet. Create one first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Existing list", selection: $selectedExistingListID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(wordListsStore.lists) { list in
                            Text(list.name).tag(Optional(list.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            case .new:
                TextField("New list name", text: $newListName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }

    private var csvEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste CSV text")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .focused($isEditorFocused)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                )

            if let errorText, errorText.isEmpty == false {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            let total = items.count
            let importable = importableItems.count
            Text(total == 0 ? "Parsed rows" : "Parsed rows: \(importable)/\(total) importable")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text("No rows parsed yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(items) { item in
                            CSVImportRow(item: item)
                            Divider()
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var importButton: some View {
        Button {
            performImport()
            dismiss()
        } label: {
            Text("Import \(importableItems.count) Word\(importableItems.count == 1 ? "" : "s")")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(importableItems.isEmpty || importSelectionIsValid == false)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                errorText = "No file selected."
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                errorText = "Failed to access the file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let decoded = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .unicode)
                    ?? String(data: data, encoding: .ascii)
                guard let decoded else {
                    errorText = "Could not decode file contents."
                    return
                }
                rawText = decoded
                errorText = nil
                items = []
                Task { await parse() }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // Runs the CSV parser and dictionary lookup off the main actor, then publishes results.
    @MainActor
    private func parse() async {
        isParsing = true
        defer { isParsing = false }
        errorText = nil
        let text = rawText
        var parsed = CSVImport.parseItems(from: text)
        await CSVImport.fillMissing(items: &parsed, dictionaryStore: dictionaryStore)
        items = parsed
    }

    // Saves all importable items to the words store and resolves or creates any requested word lists.
    private func performImport() {
        let listIDs = resolveListIDsCreatingIfNeeded()
        for item in importableItems {
            guard let surface = item.finalSurface, surface.isEmpty == false else { continue }
            var word = SavedWord(canonicalEntryID: Int64(item.id.hashValue), surface: surface, wordListIDs: listIDs)
            // Attempt to resolve the canonical entry ID from the dictionary for proper identity.
            if let store = dictionaryStore,
               let entry = resolveEntry(surface: surface, kana: item.finalKana, store: store) {
                word = SavedWord(canonicalEntryID: entry.entryId, surface: surface, wordListIDs: listIDs)
            }
            wordsStore.add(word)
        }
    }

    // Performs a synchronous best-match lookup to find the canonical dictionary entry for one import row.
    // Tries the kanji surface first, then falls back to the kana reading.
    private func resolveEntry(surface: String, kana: String?, store: DictionaryStore) -> DictionaryEntry? {
        let mode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
        if let entry = try? store.lookup(surface: surface, mode: mode).first {
            return entry
        }
        if let kana, kana.isEmpty == false, let entry = try? store.lookupExactKana(surface: kana).first {
            return entry
        }
        return nil
    }

    // MARK: - List resolution

    private var importSelectionIsValid: Bool {
        switch addToListMode {
        case .none: return true
        case .existing:
            guard let id = selectedExistingListID else { return false }
            return wordListsStore.lists.contains { $0.id == id }
        case .new:
            return newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    // Returns list IDs to assign, creating a new list if needed.
    private func resolveListIDsCreatingIfNeeded() -> [UUID] {
        switch addToListMode {
        case .none:
            return []
        case .existing:
            guard let id = selectedExistingListID,
                  wordListsStore.lists.contains(where: { $0.id == id }) else { return [] }
            return [id]
        case .new:
            let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return [] }
            // Reuse an existing list with the same name (case-insensitive) to avoid duplicates.
            if let existing = wordListsStore.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return [existing.id]
            }
            wordListsStore.create(name: name)
            if let created = wordListsStore.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return [created.id]
            }
            return []
        }
    }
}
