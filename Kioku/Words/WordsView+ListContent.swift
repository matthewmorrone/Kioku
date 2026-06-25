import SwiftUI
import AVFoundation

// List content for the Words screen. ONE word-row builder (`wordRow`) renders every
// dictionary word the app shows — live search results, saved favorites, and history
// `.entry` rows — with identical body, gestures, swipe action, and context menu. The only
// thing that varies by where the row is shown is which "Remove from …" action the menu and
// swipe offer (list / note / history), driven by the current view context. Free-text
// history `.query` rows are not words, so they keep their own small builder.
extension WordsView {
    // MARK: - The unified word row

    // The single row used for search results, saved words, and history entries. `entry` is
    // the materialized DictionaryEntry; while it's still being fetched it's nil and we fall
    // back to showing `surface`. `gloss` lets search results show the query-matched sense.
    func wordRow(
        entryID: Int64,
        surface: String,
        entry: DictionaryEntry?,
        gloss: String?,
        onTap: @escaping () -> Void
    ) -> some View {
        let saved = isSavedByID(entryID)
        let learnedState = reviewStore.learnedState(for: entryID)
        // Respect the form the word was saved/looked up as: a pure-kana surface (あなた, たとえ)
        // means the user used the kana word — showing the entry's first kanji form (貴方, 例え)
        // attaches script they never saw. Kanji-bearing surfaces keep the kanji headword.
        let surfaceIsKana = surface.isEmpty == false && ScriptClassifier.containsKanji(surface) == false
        // let headword = entry?.kanjiForms.first?.text
        // let reading = entry?.kanaForms.first?.text
        let headword = surfaceIsKana ? nil : entry?.kanjiForms.first?.text
        let reading = surfaceIsKana ? surface : entry?.kanaForms.first?.text

        // Plain content so List(selection:) keeps its native selection gestures (incl. the
        // swipe-across-rows multiselect in edit mode). The detail tap rides on a
        // simultaneousGesture so it coexists with the List's tap-to-select; the star is
        // hidden in edit mode so the row has one clear tap target.
        return HStack(spacing: 12) {
            // Leading pronunciation button. Hidden in edit mode so List(selection:)'s own
            // selection circle takes the leading slot — i.e. the audio control is "replaced
            // with the inputs" when CRUD selection is active, mirroring the trailing star.
            if editMode != .active {
                Button {
                    speakRow(reading: reading, headword: headword, surface: surface)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(japaneseTheme ? Color.white : Color.primary)
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play pronunciation")
            }
            // Central content is the only open-detail tap target. The leading speaker and
            // trailing star buttons sit OUTSIDE this region, so tapping either fires just its
            // own action — the row's simultaneousGesture (below) never covers them. (A row-wide
            // simultaneous tap would fire alongside the buttons, opening detail on a speaker tap.)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let headword {
                            Text(headword).font(.title3.weight(.semibold))
                            if let reading, reading != headword {
                                Text(reading).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else if let reading {
                            Text(reading).font(.title3.weight(.semibold))
                        } else {
                            // Pending materialization (or dict-drift orphan) — show the surface.
                            Text(surface).font(.title3.weight(.semibold))
                        }
                    }
                    if let gloss {
                        Text(gloss).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    if editMode != .active { onTap() }
                }
            )
            if editMode != .active {
                Button {
                    toggleSaveWord(entryID: entryID, surface: surface, materialized: entry)
                } label: {
                    // The mark rides on the star slot: checkmark when learned, question mark when
                    // explicitly not-learned, plain star otherwise (the word stays saved either way).
                    // Tapping still toggles save/unsave; the learned mark is set via the menu below.
                    Image(systemName: learnedIcon(state: learnedState, saved: saved))
                        .foregroundStyle(learnedIconColor(state: learnedState, saved: saved))
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? "Unsave" : "Save")
                .contextMenu {
                    learnedMenuButtons(entryID: entryID, state: learnedState)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            wordRowMenu(entryID: entryID, surface: surface, entry: entry, onTap: onTap)
        }
    }

    // MARK: - Learned state (star ↔ checkbox ↔ question mark)

    // SF Symbol for the trailing toggle, by mark: checkmark for learned, question mark for
    // explicitly not-learned, else the save star (filled when saved).
    func learnedIcon(state: LearnedState, saved: Bool) -> String {
        switch state {
        case .learned:    return "checkmark.circle.fill"
        case .notLearned: return "questionmark.circle.fill"
        case .unmarked:   return saved ? "star.fill" : "star"
        }
    }

    // Neutral (monochrome) icon color — no more yellow/blue. White under the Japanese theme,
    // primary for any filled state (learned/not-learned/saved), secondary for the empty star.
    func learnedIconColor(state: LearnedState, saved: Bool) -> Color {
        if japaneseTheme { return .white }
        if state != .unmarked || saved { return .primary }
        return .secondary
    }

    // The shared Learned / Not Learned menu pair used by the star's long-press menu and the
    // row context menu. Each row toggles its own mark — tapping the active one clears it
    // (back to unmarked) — mirroring the "tap active scope to clear" idiom in the filter sheet.
    @ViewBuilder
    func learnedMenuButtons(entryID: Int64, state: LearnedState) -> some View {
        Button {
            reviewStore.setLearnedState(state == .learned ? .unmarked : .learned, for: entryID)
        } label: {
            Label("Learned", systemImage: state == .learned ? "checkmark" : "checkmark.circle")
        }
        Button {
            reviewStore.setLearnedState(state == .notLearned ? .unmarked : .notLearned, for: entryID)
        } label: {
            Label("Not Learned", systemImage: state == .notLearned ? "checkmark" : "questionmark.circle")
        }
    }

    // Speaks the row's Japanese pronunciation via ja-JP TTS. Prefers the kana reading (least
    // ambiguous for the synthesizer), then the kanji headword, then the raw surface. Stops any
    // in-flight utterance first so rapid taps don't queue up.
    func speakRow(reading: String?, headword: String?, surface: String) {
        let text = reading ?? headword ?? surface
        guard text.isEmpty == false else { return }
        rowSpeechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        rowSpeechSynthesizer.speak(utterance)
    }

    // The single context menu for every word row. Shared items first; then the global
    // Favorite/Unfavorite (favorite == saved); then exactly the contextual "Remove from …"
    // actions that make sense where the row is being viewed. Unfavorite and "remove from a
    // container" are deliberately separate: leaving a list/note doesn't unsave the word.
    @ViewBuilder
    func wordRowMenu(
        entryID: Int64,
        surface: String,
        entry: DictionaryEntry?,
        onTap: @escaping () -> Void
    ) -> some View {
        let saved = isSavedByID(entryID)
        let copyText = entry?.kanjiForms.first?.text ?? entry?.kanaForms.first?.text ?? surface

        Button {
            UIPasteboard.general.string = copyText
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            onTap()
        } label: {
            Label("Open Details", systemImage: "info.circle")
        }
        if lemmaCandidateCount(for: surface) > 1 {
            Button {
                chooseLemma(entryID: entryID, surface: surface)
            } label: {
                Label("Choose Lemma…", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        Button(role: saved ? .destructive : nil) {
            toggleSaveWord(entryID: entryID, surface: surface, materialized: entry)
        } label: {
            Label(saved ? "Unfavorite" : "Favorite", systemImage: saved ? "star.slash" : "star")
        }

        // Learned / Not Learned marks, also reachable by long-pressing the star directly (see wordRow).
        learnedMenuButtons(entryID: entryID, state: reviewStore.learnedState(for: entryID))

        // Contextual "remove from the thing you're viewing", independent of unfavorite.
        if let listID = singleActiveListID {
            Button(role: .destructive) {
                wordsStore.removeFromList(wordIDs: [entryID], listID: listID)
            } label: {
                Label("Remove from \(listName(listID))", systemImage: "folder.badge.minus")
            }
        }
        if let noteID = singleActiveNoteID {
            Button(role: .destructive) {
                wordsStore.removeNoteMembership(wordID: entryID, noteID: noteID)
            } label: {
                Label("Remove from \(noteName(noteID))", systemImage: "minus.circle")
            }
        }
        if activeTab == .history && searchText.isEmpty {
            Button(role: .destructive) {
                historyStore.remove(canonicalEntryIDs: [entryID])
            } label: {
                Label("Remove from History", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: - List content sections

    // Saved words (already filtered by note/list via visibleWords), rendered with the
    // unified wordRow. Materialized entries come from the shared materializedHistory cache.
    @ViewBuilder
    var filteredSavedContent: some View {
        if visibleWords.isEmpty {
            Text(isFilterActive
                ? "No saved words match the current filter."
                : "No saved words yet. Tap the star on any result to save it.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(visibleWords) { word in
                let entry = materializedHistory[word.canonicalEntryID]
                // Show the user's chosen definition(s), not always the entry's first gloss, so a
                // selection change in WordDetailView is reflected here. Same resolution the
                // flashcard/multiple-choice paths use; joined for the single-line row preview.
                let rowGloss: String? = {
                    guard let joined = entry?
                        .selectedMeanings(selectedSenseIDs: word.selectedSenseIDs, selectedGlosses: word.selectedGlosses)
                        .joined(separator: "; "), joined.isEmpty == false else { return nil }
                    return joined
                }()
                wordRow(
                    entryID: word.canonicalEntryID,
                    surface: word.surface,
                    entry: entry,
                    gloss: rowGloss,
                    onTap: {
                        isSearchFieldFocused = false
                        selectedDetailWord = word
                    }
                )
                // Explicit Int64 tag so List(selection: $selectedWordIDs) binds this row.
                .tag(word.canonicalEntryID)
            }
        }
    }

    // History: word-lookup (`.entry`) rows only, via the unified wordRow. Typed `.query`
    // searches used to interleave here but disrupted the flow, so they now live in their own
    // Recent Searches scope (recentSearchesContent).
    @ViewBuilder
    var historyContent: some View {
        let entries = sortedHistory.filter { $0.kind == .entry }
        if entries.isEmpty {
            Text("No lookup history yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                let materialized = materializedHistory[entry.canonicalEntryID]
                wordRow(
                    entryID: entry.canonicalEntryID,
                    surface: entry.surface,
                    entry: materialized,
                    gloss: materialized?.senses.first?.glosses.first,
                    onTap: {
                        // Deliberately NOT re-recorded: revisiting a word from the history
                        // list shouldn't refresh its timestamp and yank it to the top —
                        // history reflects when the word was originally looked up.
                        // historyStore.record(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
                        selectedDetailWord = wordForHistory(entry)
                    }
                )
                .tag(entry.canonicalEntryID)
            }
        }
    }

    // Recent Searches scope: the typed free-text queries, newest first, each tappable to re-run
    // the search. Lives apart from History so a word-lookup log stays uncluttered by phrases.
    @ViewBuilder
    var recentSearchesContent: some View {
        let queries = sortedHistory.filter { $0.kind == .query }
        if queries.isEmpty {
            Text("No recent searches yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(queries) { entry in
                queryHistoryRow(entry)
            }
        }
    }

    // Free-text query history row — tap re-populates the search field; no save star, and
    // not a word, so it isn't selectable and doesn't use wordRow.
    @ViewBuilder
    private func queryHistoryRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.surface)
                .font(.body)
                .lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16, weight: .semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Gated so edit-mode taps toggle List selection instead of re-running the query.
        .onTapGesture {
            if editMode != .active { searchText = entry.surface }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                historyStore.remove(historyID: entry.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.surface
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                searchText = entry.surface
            } label: {
                Label("Search Again", systemImage: "magnifyingglass")
            }
            Divider()
            Button(role: .destructive) {
                historyStore.remove(historyID: entry.id)
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }
}
