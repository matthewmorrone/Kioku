import SwiftUI
import UniformTypeIdentifiers

// Controls which word list mode is selected during import.
enum CSVImportListMode: Hashable {
    case none
    case existing
    case new
    // Routes each row to its own auto-created/reused list named after CSVImportItem.chapterGroupKey
    // (e.g. "Vol 1 Ch 7") instead of one uniform list for every row — for CSVs with chapter/volume
    // columns, like Resources/human-japanese.csv. Rows with no chapter info get no list, same as .none.
    case byChapter
}

// Renders the CSV import sheet: file picker, paste editor, list assignment, preview, and import action.
// Major sections: input controls, list assignment picker, text editor, parsed preview, import button.
struct CSVImportView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore
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
    // When on, a row missing its surface adopts the dictionary's kanji form; off (default) keeps
    // the kana the user supplied, so a kana-only list isn't silently rewritten into kanji.
    @State private var fillKanjiFromDictionary: Bool = false

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
        VStack(alignment: .leading, spacing: 8) {
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

            // Off by default: a row with only kana keeps that kana as its surface. On: pull the
            // dictionary's kanji form for surface-less rows. Re-parses so the preview reflects it.
            Toggle("Fill kanji from dictionary", isOn: $fillKanjiFromDictionary)
                .font(.subheadline)
                .onChange(of: fillKanjiFromDictionary) {
                    if items.isEmpty == false { Task { await parse() } }
                }
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
                Text("By chapter").tag(CSVImportListMode.byChapter)
            }
            .pickerStyle(.segmented)

            switch addToListMode {
            case .none:
                EmptyView()
            case .existing:
                if wordListsStore.lists.isEmpty {
                    Text("No lists yet.")
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
            case .byChapter:
                let groupCount = Set(items.compactMap(\.chapterGroupKey)).count
                let hasChapterless = items.contains(where: { $0.chapterGroupKey == nil })
                Text(groupCount == 0 && hasChapterless == false
                     ? "No chapter/volume column detected in the parsed rows."
                     : "Will create/reuse \(groupCount) list\(groupCount == 1 ? "" : "s"), one per chapter\(hasChapterless ? ", plus a \"\(Self.noChapterListName)\" list for rows with none" : "").")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        await CSVImport.fillMissing(items: &parsed, dictionaryStore: dictionaryStore, fillKanjiFromDictionary: fillKanjiFromDictionary)
        items = parsed
    }

    // Saves all importable items to the words store and resolves or creates any requested word lists.
    // Runs on a detached task so the dictionary lookups happen off the main thread — DictionaryStore
    // serializes its SQLite queries on a private dispatch queue, so a per-row loop on the main actor
    // would block the UI for the duration of the import. After resolution, awaits a single batched
    // add on WordsStore (which is @MainActor), so the persist work is paid once instead of N times.
    private func performImport() {
        let items = importableItems
        // .byChapter resolves one list per row (via each row's own chapterGroupKey); every other
        // mode uses the same uniform list for all rows. `listIDs(for:)` unifies the two shapes so
        // the loop below doesn't need to branch per-row.
        let isByChapter = addToListMode == .byChapter
        let uniformListIDs = resolveListIDsCreatingIfNeeded()
        let chapterListIDs = isByChapter ? resolveChapterListIDs(for: items) : [:]
        // Resolved on the main actor, then captured as a plain (Sendable) dictionary — a local
        // func here would stay main-actor-isolated and couldn't be called from Task.detached below.
        let listIDsByItemID: [UUID: [UUID]] = Dictionary(uniqueKeysWithValues: items.map { item in
            if isByChapter {
                let key = item.chapterGroupKey ?? Self.noChapterListName
                let ids = chapterListIDs[key].map { [$0] } ?? []
                return (item.id, ids)
            }
            return (item.id, uniformListIDs)
        })

        let store = dictionaryStore
        let target = wordsStore
        let kanjiTarget = savedKanjiStore

        Task.detached(priority: .userInitiated) {
            // Split rows into kanji-only (a single character that is a kanji scalar)
            // and everything else. Kanji-only surfaces are routed to SavedKanjiStore
            // so tapping the resulting row opens KanjiDetailView, matching the user's
            // "I'm saving kanji pages, not word entries" intent. Multi-character or
            // non-kanji surfaces stay on the SavedWord path as before.
            var savedWords: [SavedWord] = []
            var kanjiLiterals: [(literal: String, listIDs: [UUID])] = []
            for item in items {
                guard let surface = item.finalSurface, surface.isEmpty == false else { continue }
                let itemListIDs = listIDsByItemID[item.id] ?? []
                if surface.count == 1,
                   let scalar = surface.unicodeScalars.first,
                   ScriptClassifier.isKanjiScalar(scalar) {
                    kanjiLiterals.append((surface, itemListIDs))
                    continue
                }
                var canonicalID = Int64(item.id.hashValue)
                var senseIDs: [Int64] = []
                if let store, let entry = Self.resolveEntry(surface: surface, kana: item.finalKana, store: store) {
                    canonicalID = entry.entryId
                    senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
                }
                savedWords.append(SavedWord(canonicalEntryID: canonicalID, surface: surface, wordListIDs: itemListIDs, selectedSenseIDs: senseIDs))
            }
            await target.add(savedWords)
            await MainActor.run {
                for (literal, itemListIDs) in kanjiLiterals {
                    kanjiTarget.save(literal: literal, wordListIDs: itemListIDs)
                }
            }
        }
    }

    // Performs a synchronous best-match lookup to find the canonical dictionary entry for one import row.
    // Tries the kanji surface first, then falls back to the kana reading. Static so the import task
    // can call it from a detached context without capturing the SwiftUI view value. `nonisolated`
    // because DictionaryStore serializes its SQL on a private queue — safe off the main actor.
    nonisolated private static func resolveEntry(surface: String, kana: String?, store: DictionaryStore) -> DictionaryEntry? {
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
        case .none, .byChapter: return true
        case .existing:
            guard let id = selectedExistingListID else { return false }
            return wordListsStore.lists.contains { $0.id == id }
        case .new:
            return newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    // Returns list IDs to assign, creating a new list if needed. Not used for .byChapter — that
    // mode resolves one list PER item via resolveChapterListIDs instead of a single uniform list.
    private func resolveListIDsCreatingIfNeeded() -> [UUID] {
        switch addToListMode {
        case .none, .byChapter:
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

    // Rows with no chapterGroupKey (no chapter/volume column value) get grouped into this shared
    // list instead of being dropped from list assignment entirely — so a chapterless row is still
    // easy to find and revisit, rather than silently landing nowhere.
    static let noChapterListName = "No Chapter"

    // Creates or reuses one WordList per distinct chapterGroupKey among the given items, plus
    // noChapterListName when any item has none, keyed by that same string so performImport can
    // look up each row's list by its own chapter (or the chapterless fallback).
    private func resolveChapterListIDs(for items: [CSVImportItem]) -> [String: UUID] {
        var keys = Set(items.compactMap(\.chapterGroupKey))
        if items.contains(where: { $0.chapterGroupKey == nil }) {
            keys.insert(Self.noChapterListName)
        }
        var result: [String: UUID] = [:]
        for key in keys {
            if let existing = wordListsStore.lists.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                result[key] = existing.id
            } else {
                result[key] = wordListsStore.create(name: key)
            }
        }
        return result
    }
}
