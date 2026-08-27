import SwiftUI

// Filter sheet for the Words screen. History/Saved is the one mutually-exclusive "base
// view" choice (a 2-way segmented control, since exactly one is always showing) — History
// includes both word lookups and typed free-text searches together, newest first. Everything
// else — Review Status, JLPT Level, Note, List, plus Sort and Kanji below — is an independent,
// composable narrowing filter with its own row/menu, mirroring how Sort and Kanji already
// worked: picking a Review Status AND a Note AND a List all combine (see
// WordsView+Actions.visibleWords, which already ANDs them together). Picking any of these
// narrowing filters switches the base view to Saved, since they only apply to saved words.
struct WordsFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore
    @EnvironmentObject private var notesStore: NotesStore

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>
    @Binding var statScope: WordsStatScope
    // Active JLPT-level scope (N-number 5…1) or nil. Single-value like the other narrowing filters.
    @Binding var jlptLevel: Int?
    // True when the screen shows the saved list rather than the lookup history.
    @Binding var showSavedWords: Bool
    @Binding var sortOrder: WordsSortOrder
    // Orthogonal kanji-content refinement; composes with every other filter rather than
    // replacing them. Off by default (pure-kana only).
    @Binding var showKanji: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Base view", selection: $showSavedWords) {
                        Text("History").tag(false)
                        Text("Saved").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section { reviewStatusRow }
                Section { jlptLevelRow }
                if notesWithSavedWords.isEmpty == false {
                    Section { noteRow }
                }
                Section {
                    listRow
                    NavigationLink("Manage Lists…") {
                        ManageWordListsView(
                            activeFilterListIDs: $activeFilterListIDs,
                            showSavedWords: $showSavedWords
                        )
                    }
                }

                Section {
                    Picker(selection: $sortOrder) {
                        ForEach(WordsSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    } label: {
                        Text("Sort")
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Toggle("Show Kanji", isOn: $showKanji)
                }
            }
            .navigationTitle("Show")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Narrowing filter rows

    private var reviewStatusRow: some View {
        Menu {
            Button { tapStatScope(.markedWrong) } label: {
                Label(markedWrongLabel, systemImage: statScope == .markedWrong ? "checkmark" : "xmark.circle")
            }
            Button { tapStatScope(.dueForReview) } label: {
                Label(dueForReviewLabel, systemImage: statScope == .dueForReview ? "checkmark" : "clock")
            }
            Button { tapStatScope(.neverReviewed) } label: {
                Label(neverReviewedLabel, systemImage: statScope == .neverReviewed ? "checkmark" : "circle.dashed")
            }
            Button { tapStatScope(.learned) } label: {
                Label(learnedLabel, systemImage: statScope == .learned ? "checkmark" : "checkmark.circle")
            }
            Button { tapStatScope(.notLearned) } label: {
                Label(notLearnedLabel, systemImage: statScope == .notLearned ? "checkmark" : "questionmark.circle")
            }
        } label: {
            filterRowLabel(title: "Review Status", value: reviewStatusLabel)
        }
    }

    // JLPT proficiency level (N5 easiest … N1 hardest). Levels are unofficial estimates; only
    // saved words with a known level appear. Re-tapping the active level clears back to "Any".
    private var jlptLevelRow: some View {
        Menu {
            // N-numbers descend 5→1 so the menu reads N5 (easiest) first.
            ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { level in
                Button { tapJLPT(level) } label: {
                    Label("N\(level)", systemImage: jlptLevel == level ? "checkmark" : "graduationcap")
                }
            }
        } label: {
            filterRowLabel(title: "JLPT Level", value: jlptLevelLabel)
        }
    }

    private var noteRow: some View {
        Menu {
            ForEach(notesWithSavedWords) { (note: Note) in
                Button { tapNote(note.id) } label: {
                    Label(note.resolvedTitle,
                          systemImage: activeFilterNoteIDs.contains(note.id) ? "checkmark" : "doc.text")
                }
            }
        } label: {
            filterRowLabel(title: "Note", value: noteLabel)
        }
    }

    // Pure filter menu, mirroring noteRow — list creation/rename/reorder/delete live in
    // ManageWordListsView (reached via the "Manage Lists…" row alongside this one).
    private var listRow: some View {
        Menu {
            ForEach(wordListsStore.lists) { (list: WordList) in
                Button { tapList(list.id) } label: {
                    Label("\(list.name)  (\(wordCount(for: list.id)))",
                          systemImage: activeFilterListIDs.contains(list.id) ? "checkmark" : "folder")
                }
            }
        } label: {
            filterRowLabel(title: "List", value: listLabel)
        }
    }

    // Shared row chrome for the narrowing-filter menus above, matching the base-view row's look.
    private func filterRowLabel(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Row value labels

    private var reviewStatusLabel: String {
        switch statScope {
        case .none:          return "Any"
        case .markedWrong:   return "Marked Wrong"
        case .dueForReview:  return "Due for Review"
        case .neverReviewed: return "Never Reviewed"
        case .learned:       return "Learned"
        case .notLearned:    return "Not Learned"
        }
    }

    private var jlptLevelLabel: String {
        jlptLevel.map { "N\($0)" } ?? "Any"
    }

    private var noteLabel: String {
        guard let noteID = activeFilterNoteIDs.first, let note = notesStore.note(withID: noteID) else { return "Any" }
        return note.resolvedTitle
    }

    private var listLabel: String {
        guard let listID = activeFilterListIDs.first,
              let list = wordListsStore.lists.first(where: { $0.id == listID }) else { return "Any" }
        return list.name
    }

    // Badge labels showing counts for each stat scope option.
    private var markedWrongLabel: String {
        let count = wordsStore.words.filter { wordsStore.markedWrong.contains($0.canonicalEntryID) }.count
        return count > 0 ? "Marked Wrong (\(count))" : "Marked Wrong"
    }

    private var dueForReviewLabel: String {
        let count = wordsStore.words.filter { wordsStore.isDueForReview(id: $0.canonicalEntryID) }.count
        return "Due for Review (\(count))"
    }

    private var neverReviewedLabel: String {
        let count = wordsStore.words.filter { wordsStore.stats[$0.canonicalEntryID] == nil }.count
        return count > 0 ? "Never Reviewed (\(count))" : "Never Reviewed"
    }

    private var learnedLabel: String {
        let count = wordsStore.words.filter { wordsStore.isLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Learned (\(count))" : "Learned"
    }

    private var notLearnedLabel: String {
        let count = wordsStore.words.filter { wordsStore.isNotLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Not Learned (\(count))" : "Not Learned"
    }

    // MARK: - Narrowing filter selection (each is independent; re-tapping the active choice clears
    // just that one filter — the others, and the base view, are untouched)

    private func tapStatScope(_ scope: WordsStatScope) {
        statScope = statScope == scope ? .none : scope
        activateSaved()
    }

    // Toggles a JLPT-level filter; re-tapping the active level clears it.
    private func tapJLPT(_ level: Int) {
        jlptLevel = jlptLevel == level ? nil : level
        activateSaved()
    }

    // Toggles a note filter; re-tapping the active note clears it.
    private func tapNote(_ noteID: UUID) {
        activeFilterNoteIDs = activeFilterNoteIDs.contains(noteID) ? [] : [noteID]
        activateSaved()
    }

    // Toggles a list filter; re-tapping the active list clears it.
    private func tapList(_ listID: UUID) {
        activeFilterListIDs = activeFilterListIDs.contains(listID) ? [] : [listID]
        activateSaved()
    }

    // Narrowing filters only apply to saved words (see WordsView+Actions.visibleWords), so
    // picking one always switches the base view to Saved.
    private func activateSaved() {
        showSavedWords = true
    }

    // MARK: - Data helpers

    // Counts saved members of a given list — words + kanji. Both record types
    // share the same WordList ids (see SavedKanji.wordListIDs), so a kanji-only
    // list registers a non-zero count instead of the misleading "Animated (0)"
    // we'd get from counting only SavedWord entries.
    private func wordCount(for listID: UUID) -> Int {
        let words = wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        let kanji = savedKanjiStore.kanji.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        return words + kanji
    }

    // Only notes that have at least one saved word in the store are shown.
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }
}
