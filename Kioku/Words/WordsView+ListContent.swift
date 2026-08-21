import SwiftUI
import AVFoundation

// Applies .swipeActions only when not editing — merely attaching the modifier (even with an
// empty action set) fights List(selection:)'s native multi-select circle for the same row
// gesture machinery, so this omits the modifier entirely rather than just hiding its content.
private struct SwipeActionsWhenNotEditing<Actions: View>: ViewModifier {
    let isEditing: Bool
    @ViewBuilder let actions: () -> Actions

    // Omits .swipeActions entirely while editing instead of just emptying its content.
    func body(content: Content) -> some View {
        if isEditing {
            content
        } else {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true, content: actions)
        }
    }
}

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
    // `chosenReading` is the reading the user pinned with the detail view's reading switcher —
    // only saved-word rows have one, so it defaults to nil for search-result and history rows.
    func wordRow(
        entryID: Int64,
        surface: String,
        entry: DictionaryEntry?,
        gloss: String?,
        chosenReading: String? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        let saved = isSavedByID(entryID)
        let learnedState = wordsStore.learnedState(for: entryID)
        // Respect the form the word was saved/looked up as: a pure-kana surface (あなた, たとえ)
        // means the user used the kana word — showing the entry's first kanji form (貴方, 例え)
        // attaches script they never saw. Kanji-bearing surfaces keep the kanji headword.
        let surfaceIsKana = surface.isEmpty == false && ScriptClassifier.containsKanji(surface) == false
        // let headword = entry?.kanjiForms.first?.text
        // let reading = entry?.kanaForms.first?.text
        let headword = surfaceIsKana ? nil : entry?.kanjiForms.first?.text
        // A reading the user pinned with the detail view's reading switcher wins over the entry's
        // first kana form (涙 shows なだ, not なみだ, once switched) — otherwise the switch appeared
        // to do nothing back in the list. Validated against the entry's own kana forms so a reading
        // left over from a dictionary rebuild or a re-point can't render a form this entry lacks.
        let pinnedReading: String? = {
            guard let chosenReading, let entry else { return nil }
            return entry.kanaForms.contains { $0.text == chosenReading } ? chosenReading : nil
        }()
        let reading = pinnedReading ?? (surfaceIsKana ? surface : entry?.kanaForms.first?.text)

        // While editing, central content stays a plain view (see its comment below) so
        // List(selection:) keeps its native selection gestures (incl. the swipe-across-rows
        // multiselect); the star is hidden in edit mode so the row has one clear tap target.
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
            // own action.
            //
            // Two different shapes depending on edit mode, not one view with a gesture modifier:
            // .contextMenu reliably coexists with a Button's own tap recognizer (proven by the
            // star button, which has always worked this way) but silently fails to fire when the
            // only tap handling nearby is .onTapGesture or .simultaneousGesture(TapGesture())
            // instead — which is what this used to be, and why the row's long-press menu stopped
            // appearing. But a Button here would also compete with List(selection:)'s own
            // native row-tap-to-select gesture while editing, which the previous
            // simultaneousGesture was specifically chosen to stay out of the way of — so edit
            // mode keeps the old plain-view shape (no Button, no gesture, no context menu) and
            // lets List(selection:) handle the tap entirely on its own; only the normal,
            // non-editing shape needs to satisfy .contextMenu.
            if editMode == .active {
                wordRowCentralContent(headword: headword, reading: reading, surface: surface, gloss: gloss)
                    .contentShape(Rectangle())
            } else {
                Button {
                    onTap()
                } label: {
                    wordRowCentralContent(headword: headword, reading: reading, surface: surface, gloss: gloss)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    wordRowMenu(entryID: entryID, surface: surface, entry: entry, onTap: onTap)
                }
            }
            if editMode != .active {
                Button {
                    toggleSaveWord(entryID: entryID, surface: surface, materialized: entry)
                } label: {
                    // The mark rides on the star slot: checkmark when learned, question mark when
                    // explicitly not-learned, plain star otherwise (the word stays saved either way).
                    // Tapping toggles save; the mark is set via the long-press context menu.
                    Image(systemName: learnedIcon(state: learnedState, saved: saved))
                        .foregroundStyle(learnedIconColor(state: learnedState, saved: saved))
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? "Unsave" : "Save")
                .contextMenu {
                    learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(entryID: entryID, wordsStore: wordsStore))
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Attaching .swipeActions at all — even with an empty button set — fights
        // List(selection:)'s native multi-select circle for the same row gesture machinery,
        // leaving the circle visually stuck on whichever row last rendered it. So this isn't
        // just "hide the buttons," it's "don't attach the modifier" while editing. Edit mode
        // already has its own batch remove via the toolbar, so swipe isn't needed there anyway.
        //
        // The learned-state marks ride along here too, not just on the star's own .contextMenu
        // above: List(selection:)'s native row-selection gesture machinery makes .contextMenu
        // unreliable on its rows (same root cause as the Lines row's star menu — see
        // SegmentListView's comment on that), so this is the belt to that menu's suspenders
        // rather than a replacement for it. Remove/Unfavorite stays first so a full swipe keeps
        // doing what it always did.
        .modifier(SwipeActionsWhenNotEditing(isEditing: editMode == .active) {
            wordRowSwipeAction(entryID: entryID, surface: surface, entry: entry)
            Menu {
                learnedStateMenuButtons(currentState: learnedState, setState: learnedStateSetter(entryID: entryID, wordsStore: wordsStore))
            } label: {
                Label("Mark…", systemImage: "ellipsis.circle")
            }
        })
    }

    // wordRow's central headword/reading/gloss block, factored out so its edit-mode and
    // non-edit-mode branches (a plain view vs. a Button, per wordRow's comment) can share the
    // same content instead of duplicating it inline in both branches.
    @ViewBuilder
    private func wordRowCentralContent(headword: String?, reading: String?, surface: String, gloss: String?) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                // ViewThatFits tries the inline HStack (headword + reading side by side, one
                // line) first; for a long headword like a whole example sentence, that doesn't
                // fit at .lineLimit(1) and it falls back to stacking the reading on its own line
                // below instead of wrapping the two mid-word next to each other.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headwordReadingTexts(headword: headword, reading: reading, surface: surface)
                    }
                    .lineLimit(1)

                    VStack(alignment: .leading, spacing: 2) {
                        headwordReadingTexts(headword: headword, reading: reading, surface: surface)
                    }
                }
                if let gloss {
                    Text(gloss).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // The headword + reading (or surface fallback) content, factored out so wordRow's
    // ViewThatFits can place the identical Text sequence inside either an HStack (inline, one
    // line) or a VStack (stacked) without duplicating the branching logic.
    @ViewBuilder
    private func headwordReadingTexts(headword: String?, reading: String?, surface: String) -> some View {
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

    // The single trailing-swipe "remove" action, contextual to whichever scope the row is
    // being viewed in — same priority order as wordRowMenu's "remove from …" section (list →
    // note → history), falling back to Unfavorite everywhere else (the Saved Words list, plain
    // search results). One action per row keeps the swipe gesture a predictable single-purpose
    // "take this out of what I'm looking at" rather than a menu of choices.
    @ViewBuilder
    private func wordRowSwipeAction(entryID: Int64, surface: String, entry: DictionaryEntry?) -> some View {
        // role: .destructive alone should color these red, but something in this app's theming
        // overrides it — force it explicitly rather than rely on the default.
        if let listID = singleActiveListID {
            Button(role: .destructive) {
                wordsStore.removeFromList(wordIDs: [entryID], listID: listID)
            } label: {
                Label("Remove", systemImage: "folder.badge.minus")
            }
            .tint(.red)
        } else if let noteID = singleActiveNoteID {
            Button(role: .destructive) {
                wordsStore.removeNoteMembership(wordID: entryID, noteID: noteID)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .tint(.red)
        } else if activeTab == .history && searchText.isEmpty {
            Button(role: .destructive) {
                historyStore.remove(canonicalEntryIDs: [entryID])
            } label: {
                Label("Remove", systemImage: "clock.arrow.circlepath")
            }
            .tint(.red)
        } else if isSavedByID(entryID) {
            Button(role: .destructive) {
                toggleSaveWord(entryID: entryID, surface: surface, materialized: entry)
            } label: {
                Label("Unfavorite", systemImage: "star.slash")
            }
            .tint(.red)
        }
    }

    // MARK: - Learned state (star ↔ checkbox ↔ question mark)

    // SF Symbol for the trailing toggle, by mark: a plain checkmark for learned, a plain
    // question mark for explicitly not-learned, else the save star (filled when saved). Gated on
    // `saved` — ReviewStore's Learned/Not-Learned mark is keyed by canonicalEntryID and outlives
    // the SavedWord card, so an unsaved word always reverts to the hollow star instead of keeping
    // its old glyph, which would otherwise make an unsave tap look like it did nothing.
    func learnedIcon(state: LearnedState, saved: Bool) -> String {
        guard saved else { return "star" }
        switch state {
        case .learned:    return "checkmark"
        case .notLearned: return "questionmark"
        case .unmarked:   return "star.fill"
        }
    }

    // Neutral (monochrome) icon color — no more yellow/blue. White under the Japanese theme,
    // primary while saved (any mark), secondary for the empty/unsaved star.
    func learnedIconColor(state: LearnedState, saved: Bool) -> Color {
        if japaneseTheme { return .white }
        return saved ? .primary : .secondary
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

        // Add-to-list submenu — every user list appears as a toggleable row, with
        // a checkmark when the word is already in that list. Tapping a non-member
        // list saves the word first if needed (toggleListMembership is a no-op on
        // unsaved words), so users can add a search-result row to a list in one
        // gesture without first having to favorite it.
        if wordListsStore.lists.isEmpty == false {
            let memberLists: Set<UUID> = Set(wordsStore.words.first { $0.canonicalEntryID == entryID }?.wordListIDs ?? [])
            Menu {
                ForEach(wordListsStore.lists) { list in
                    Button {
                        addOrToggleListMembership(entryID: entryID, surface: surface, materialized: entry, listID: list.id)
                    } label: {
                        if memberLists.contains(list.id) {
                            Label(list.name, systemImage: "checkmark")
                        } else {
                            Text(list.name)
                        }
                    }
                }
            } label: {
                Label("Add to List", systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button(role: saved ? .destructive : nil) {
            toggleSaveWord(entryID: entryID, surface: surface, materialized: entry)
        } label: {
            Label(saved ? "Unfavorite" : "Favorite", systemImage: saved ? "star.slash" : "star")
        }

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

    // Saved kanji rendered as a distinct section at the top of the Saved tab. Uses
    // the same kanji-tile row shape as the search-results section, so the user gets
    // visual continuity: a tinted square kanji tile + meanings + grade/JLPT pills,
    // tapping opens KanjiDetailView. Hidden when no kanji are saved (or when the
    // current note/list filter excludes all of them) — no phantom "Kanji" header.
    @ViewBuilder
    var savedKanjiContent: some View {
        if visibleSavedKanji.isEmpty == false {
            Section("Kanji") {
                ForEach(visibleSavedKanji) { saved in
                    if let info = materializedSavedKanji[saved.literal] {
                        savedKanjiRow(info: info, saved: saved)
                    }
                }
            }
        }
    }

    // One saved-kanji row. Out of edit mode it's a button that opens the kanji detail and
    // carries the reorganize/Unfavorite context menu. In edit mode it becomes a manually
    // selectable row that toggles membership in selectedKanjiLiterals — the parallel selection
    // set that lets the batch "Remove from Saved" delete kanji alongside words. Kanji can't use
    // the List's native selection because that's keyed to Int64 word ids, not String literals.
    @ViewBuilder
    func savedKanjiRow(info: KanjiInfo, saved: SavedKanji) -> some View {
        if editMode == .active {
            let isSelected = selectedKanjiLiterals.contains(saved.literal)
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                kanjiResultRowContent(info)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelected {
                    selectedKanjiLiterals.remove(saved.literal)
                } else {
                    selectedKanjiLiterals.insert(saved.literal)
                }
            }
            .listRowBackground(Color.accentColor.opacity(0.06))
        } else {
            HStack(spacing: 12) {
                Button {
                    isSearchFieldFocused = false
                    presentedKanjiInfo = info
                } label: {
                    kanjiResultRowContent(info)
                }
                .buttonStyle(.plain)
                kanjiSaveStar(literal: saved.literal)
            }
            .listRowBackground(Color.accentColor.opacity(0.06))
            .contextMenu { savedKanjiRowMenu(info: info, saved: saved) }
        }
    }

    // Trailing save star for a kanji row — the kanji analogue of the word row's star.
    // Filled when the literal is saved, tapping toggles save/unsave through SavedKanjiStore.
    // Sits outside the row's open-detail tap target so a star tap never opens the detail
    // sheet. Color follows the word-row convention: white under the Japanese theme,
    // primary when saved, secondary for the empty star.
    @ViewBuilder
    func kanjiSaveStar(literal: String) -> some View {
        let saved = savedKanjiStore.contains(literal: literal)
        Button {
            savedKanjiStore.toggle(literal: literal)
        } label: {
            Image(systemName: saved ? "star.fill" : "star")
                .foregroundStyle(japaneseTheme ? Color.white : (saved ? Color.primary : Color.secondary))
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(.plain)
        // Include the literal so VoiceOver distinguishes one kanji star from another in a
        // mixed word/kanji list, and name the type ("kanji") since the word-row star is just
        // "Save"/"Unsave".
        .accessibilityLabel(saved ? "Unsave kanji \(literal)" : "Save kanji \(literal)")
    }

    // Long-press context menu for a saved-kanji row. Mirrors the word-row menu's
    // shape — Open / Add to List / Remove from current list / Unfavorite —
    // routed through SavedKanjiStore. Without this, kanji were saveable but
    // couldn't be reorganized or removed from the Saved view.
    @ViewBuilder
    func savedKanjiRowMenu(info: KanjiInfo, saved: SavedKanji) -> some View {
        Button {
            presentedKanjiInfo = info
        } label: {
            Label("Open Details", systemImage: "info.circle")
        }

        if wordListsStore.lists.isEmpty == false {
            let memberLists: Set<UUID> = Set(saved.wordListIDs)
            Menu {
                ForEach(wordListsStore.lists) { list in
                    Button {
                        savedKanjiStore.setListMembership(
                            literal: saved.literal,
                            listID: list.id,
                            isMember: memberLists.contains(list.id) == false
                        )
                    } label: {
                        if memberLists.contains(list.id) {
                            Label(list.name, systemImage: "checkmark")
                        } else {
                            Text(list.name)
                        }
                    }
                }
            } label: {
                Label("Add to List", systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button(role: .destructive) {
            savedKanjiStore.remove(literal: saved.literal)
        } label: {
            Label("Unfavorite", systemImage: "star.slash")
        }

        if let listID = singleActiveListID {
            Button(role: .destructive) {
                savedKanjiStore.setListMembership(literal: saved.literal, listID: listID, isMember: false)
            } label: {
                Label("Remove from \(listName(listID))", systemImage: "folder.badge.minus")
            }
        }
    }

    // Saved words (already filtered by note/list via visibleWords), rendered with the
    // unified wordRow. Materialized entries come from the shared materializedHistory cache.
    // The empty-state message is suppressed when the sibling savedKanjiContent section
    // has visible kanji — otherwise a list that only contains kanji would render the
    // misleading "No saved words match" message even though the list isn't empty.
    @ViewBuilder
    var filteredSavedContent: some View {
        if visibleWords.isEmpty {
            if visibleSavedKanji.isEmpty {
                Text(isFilterActive
                    ? "No saved words match the current filter."
                    : "No saved words yet.")
                    .foregroundStyle(.secondary)
            }
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
                    chosenReading: word.selectedReading,
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

    // History: word-lookup (`.entry`) rows via the unified wordRow, interleaved with typed
    // free-text (`.query`) rows via queryHistoryRow — one chronological log, newest first.
    @ViewBuilder
    var historyContent: some View {
        let entries = sortedHistory
        if entries.isEmpty {
            Text("No lookup history yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                switch entry.kind {
                case .entry:
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
                case .query:
                    queryHistoryRow(entry)
                }
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
