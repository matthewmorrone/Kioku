import SwiftUI

// Renders the Learn Spelling form, opened from the lookup sheet for a word with no dictionary entry
// and from Custom Words to edit a learned one. Layout: the spelling; a Same Word / New Word picker;
// for Same Word, a search field and the matching dictionary entries to pick from; for New Word,
// reading and meaning fields. Cancel and Save in the toolbar.
struct LearnSpellingView: View {
    let dictionaryStore: DictionaryStore?
    let existing: LearnedWord?
    let onFinish: () -> Void

    @EnvironmentObject private var learnedWordStore: LearnedWordStore
    @State private var spelling: String
    @State private var mode: LearnSpellingMode
    @State private var query: String
    @State private var results: [DictionaryEntry] = []
    @State private var selectedEntryID: Int64?
    @State private var reading: String
    @State private var meaning: String

    // Prefills from the tapped surface, or from the learned word being edited.
    init(surface: String, dictionaryStore: DictionaryStore?, existing: LearnedWord? = nil, onFinish: @escaping () -> Void) {
        self.dictionaryStore = dictionaryStore
        self.existing = existing
        self.onFinish = onFinish
        _spelling = State(initialValue: existing?.spelling ?? surface)
        switch existing?.kind {
        case .newWord(let reading, let meaning):
            _mode = State(initialValue: .newWord)
            _query = State(initialValue: surface)
            _reading = State(initialValue: reading)
            _meaning = State(initialValue: meaning)
        case .spellingOf(let entSeq):
            let entry = dictionaryStore?.entryID(forEntSeq: entSeq).flatMap { try? dictionaryStore?.lookupEntry(entryID: $0) }
            _mode = State(initialValue: .sameWord)
            _query = State(initialValue: entry.map(Self.headword) ?? surface)
            _selectedEntryID = State(initialValue: entry?.entryId)
            _reading = State(initialValue: "")
            _meaning = State(initialValue: "")
        case nil:
            _mode = State(initialValue: .sameWord)
            _query = State(initialValue: surface)
            _reading = State(initialValue: "")
            _meaning = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Spelling") {
                    TextField("Spelling", text: $spelling)
                }
                Section {
                    Picker("Kind", selection: $mode) {
                        Text("Same Word As").tag(LearnSpellingMode.sameWord)
                        Text("New Word").tag(LearnSpellingMode.newWord)
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
                    Section {
                        TextField("Reading", text: $reading)
                        TextField("Meaning", text: $meaning)
                    }
                }
            }
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

    // Save needs a spelling plus a picked entry, or a reading and meaning.
    private var canSave: Bool {
        guard spelling.trimmingCharacters(in: .whitespaces).isEmpty == false else { return false }
        switch mode {
        case .sameWord: return selectedEntryID != nil
        case .newWord:
            return reading.trimmingCharacters(in: .whitespaces).isEmpty == false
                && meaning.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
    }

    // Stores the learned word (replacing the edited one) and closes the form. ContentView rebuilds
    // the read resources when the store changes, which writes it into the dictionary.
    private func save() {
        let kind: LearnedWordKind
        switch mode {
        case .sameWord:
            guard let selectedEntryID, let entSeq = dictionaryStore?.entSeq(forEntryID: selectedEntryID) else { return }
            kind = .spellingOf(entSeq: entSeq)
        case .newWord:
            kind = .newWord(
                reading: reading.trimmingCharacters(in: .whitespaces),
                meaning: meaning.trimmingCharacters(in: .whitespaces)
            )
        }
        let trimmedSpelling = spelling.trimmingCharacters(in: .whitespaces)
        if var existing {
            existing.spelling = trimmedSpelling
            existing.kind = kind
            learnedWordStore.update(existing)
        } else {
            learnedWordStore.save(spelling: trimmedSpelling, kind: kind)
        }
        onFinish()
    }

    // Searches the dictionary for the query (Japanese or English), keeping the picked entry listed.
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
        let mode: DictionarySearchMode = term.unicodeScalars.contains { $0.value > 0x2E80 } ? .japanese : .english
        do {
            results = try dictionaryStore.searchEntries(term: term, mode: mode, limit: 20)
        } catch {
            AppLog.error(.dictionary, "Learn Spelling search failed: \(error)")
            results = []
        }
    }

    // The entry's first kanji form, or its first reading for kana-only words.
    private static func headword(_ entry: DictionaryEntry) -> String {
        entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? entry.matchedSurface
    }
}
