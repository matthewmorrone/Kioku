import SwiftUI

// Renders the custom-word editor, opened from the lookup sheet's Learn Spelling (prefilled with the
// tapped word) and from Custom Words to add or edit a word. Layout: Kanji and Kana spellings; a
// Same Word / New Word picker; for Same Word, a search field and matching dictionary entries to
// pick; for New Word, one section per meaning (glosses, part of speech, tags) and Add Meaning.
// Cancel and Save in the toolbar.
struct CustomWordEditorView: View {
    let dictionaryStore: DictionaryStore?
    let existing: CustomWord?
    let onFinish: () -> Void

    @EnvironmentObject private var customWordStore: CustomWordStore
    @State private var kanjiText: String
    @State private var kanaText: String
    @State private var mode: CustomWordEditorMode
    @State private var query: String
    @State private var results: [DictionaryEntry] = []
    @State private var selectedEntryID: Int64?
    @State private var senses: [CustomWordSenseDraft]

    // Prefills from the word being edited, or from a tapped spelling (into Kanji or Kana by script).
    init(existing: CustomWord?, spelling: String = "", dictionaryStore: DictionaryStore?, onFinish: @escaping () -> Void) {
        self.dictionaryStore = dictionaryStore
        self.existing = existing
        self.onFinish = onFinish
        let spellingHasKanji = ScriptClassifier.containsKanji(spelling)
        _kanjiText = State(initialValue: existing.map { $0.kanji.joined(separator: ", ") } ?? (spellingHasKanji ? spelling : ""))
        _kanaText = State(initialValue: existing.map { $0.kana.joined(separator: ", ") } ?? (spellingHasKanji ? "" : spelling))
        let linkedEntry = existing?.sameAsEntSeq
            .flatMap { dictionaryStore?.entryID(forEntSeq: $0) }
            .flatMap { try? dictionaryStore?.lookupEntry(entryID: $0) }
        _mode = State(initialValue: existing == nil || existing?.sameAsEntSeq != nil ? .sameWord : .newWord)
        _query = State(initialValue: linkedEntry.map(Self.headword) ?? spelling)
        _selectedEntryID = State(initialValue: linkedEntry?.entryId)
        let drafts = existing?.senses.map {
            CustomWordSenseDraft(glosses: $0.glosses.joined(separator: "; "), partOfSpeech: $0.partOfSpeech.joined(separator: ", "), misc: $0.misc.joined(separator: ", "))
        } ?? []
        _senses = State(initialValue: drafts.isEmpty ? [CustomWordSenseDraft(glosses: "", partOfSpeech: "", misc: "")] : drafts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Spelling") {
                    TextField("Kanji", text: $kanjiText)
                    TextField("Kana", text: $kanaText)
                }
                Section {
                    Picker("Kind", selection: $mode) {
                        Text("Same Word As").tag(CustomWordEditorMode.sameWord)
                        Text("New Word").tag(CustomWordEditorMode.newWord)
                    }
                    .pickerStyle(.segmented)
                }
                switch mode {
                case .sameWord:
                    Section {
                        TextField("Search", text: $query)
                        ForEach(results, id: \.entryId) { entry in
                            resultRow(entry)
                        }
                    }
                case .newWord:
                    ForEach($senses) { $sense in
                        Section {
                            TextField("Meaning", text: $sense.glosses)
                            TextField("Part of Speech", text: $sense.partOfSpeech)
                            TextField("Tags", text: $sense.misc)
                            if senses.count > 1 {
                                Button("Remove Meaning", role: .destructive) {
                                    senses.removeAll { $0.id == sense.id }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Add Meaning") {
                            senses.append(CustomWordSenseDraft(glosses: "", partOfSpeech: "", misc: ""))
                        }
                    }
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onFinish)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(canSave == false)
                }
            }
            .task(id: query) { await search() }
        }
    }

    // One dictionary entry to pick: headword, reading and first gloss, checked when selected.
    private func resultRow(_ entry: DictionaryEntry) -> some View {
        Button {
            selectedEntryID = entry.entryId
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.headword(entry)).foregroundStyle(.primary)
                    Text([entry.kanaForms.first?.text, entry.senses.first?.glosses.first].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selectedEntryID == entry.entryId {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    // Save needs a spelling, plus a picked entry or a reading and at least one meaning.
    private var canSave: Bool {
        let kanji = Self.items(kanjiText), kana = Self.items(kanaText)
        guard kanji.isEmpty == false || kana.isEmpty == false else { return false }
        switch mode {
        case .sameWord: return selectedEntryID != nil
        case .newWord: return kana.isEmpty == false && builtSenses.isEmpty == false
        }
    }

    // The meanings that have at least one gloss.
    private var builtSenses: [CustomWordSense] {
        senses.map { draft in
            CustomWordSense(
                partOfSpeech: Self.items(draft.partOfSpeech),
                misc: Self.items(draft.misc),
                glosses: draft.glosses.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
            )
        }
        .filter { $0.glosses.isEmpty == false }
    }

    // Stores the word (replacing the edited one, keeping its identity) and closes the editor.
    // ContentView rebuilds the read resources when the store changes, which writes it into the
    // dictionary.
    private func save() {
        var word = existing ?? CustomWord(id: UUID(), entSeq: nil, sameAsEntSeq: nil, kanji: [], kana: [], senses: [], defaultKey: nil)
        word.kanji = Self.items(kanjiText)
        word.kana = Self.items(kanaText)
        switch mode {
        case .sameWord:
            guard let selectedEntryID, let entSeq = dictionaryStore?.entSeq(forEntryID: selectedEntryID) else { return }
            word.sameAsEntSeq = entSeq
            word.senses = []
        case .newWord:
            word.sameAsEntSeq = nil
            word.senses = builtSenses
        }
        customWordStore.save(word)
        onFinish()
    }

    // Searches the dictionary for the query (Japanese or English) after a short pause in typing.
    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard let dictionaryStore, term.isEmpty == false else {
            results = []
            return
        }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            return
        }
        let searchMode: DictionarySearchMode = term.unicodeScalars.contains { $0.value > 0x2E80 } ? .japanese : .english
        do {
            results = try dictionaryStore.searchEntries(term: term, mode: searchMode, limit: 20)
        } catch {
            AppLog.error(.dictionary, "custom word search failed: \(error)")
            results = []
        }
    }

    // Comma- or 、-separated items, trimmed, blanks dropped.
    private static func items(_ text: String) -> [String] {
        text.split(whereSeparator: { ",、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
    }

    // The entry's first kanji form, or its first reading for kana-only words.
    private static func headword(_ entry: DictionaryEntry) -> String {
        entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? entry.matchedSurface
    }
}
