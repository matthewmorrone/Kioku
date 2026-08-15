import SwiftUI

// Renders the flashcard study mode: home configuration, active session, and session summary.
// Major sections: toolbar, session header, card stack, grading controls, review home form, session complete state.
struct FlashcardsView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Read-tab reading maps, forwarded to WordDetailView for example-sentence furigana.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    // When non-nil, this view opens directly into a session over exactly these words (skipping the
    // home pickers) — used by the Coverage screen to drill a specific level × stage word set.
    var presetWords: [SavedWord]? = nil
    // The card cap the Coverage launch sheet's count field settled on; nil (rather than 0) means
    // "use the default", so a preset launch can still ask for "all" via 0 explicitly.
    var presetCardCount: Int? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @Environment(\.dismiss) private var dismiss

    @State private var session: [SavedWord] = []
    @State private var sessionSource: [SavedWord] = []
    // Ensures the preset session auto-starts only once, so ending it doesn't immediately restart.
    @State private var didAutoStartPreset: Bool = false
    // True for the lifetime of a Coverage-launched sheet. Governs the toolbar close affordance and
    // what "End"/"Choose Different Cards" do: a preset session has no generic home screen to fall
    // back to (its scope came from a specific coverage cell, not the note/scope/level pickers
    // below), so those actions dismiss the sheet back to Coverage instead of landing on the
    // unscoped, all-notes `reviewHome`.
    @State private var isPresetSession: Bool = false
    @State private var index: Int = 0
    @State private var showBack: Bool = false

    @State private var dragOffset: CGSize = .zero
    @State private var isSwipingOut: Bool = false
    @State private var swipeDirection: Int = 0

    @State private var sessionCorrect: Int = 0
    @State private var sessionAgain: Int = 0
    @State private var sessionTotalCount: Int = 0
    @State private var reviewedCount: Int = 0

    @State private var showEndSessionConfirm: Bool = false
    // When on, a card whose resolved direction is englishToJapanese (production: meaning→kanji/kana)
    // is graded by typing the answer (via AnswerScorer) instead of self-reported flip+Know/Again.
    // Cards that resolve to japaneseToEnglish, kanjiToKana, or kanaToKanji are unaffected — the
    // former because English answers have too many valid phrasings to fuzzy-match reliably; the
    // latter two stay self-graded-only in this first pass (AnswerScorer would handle them fine, but
    // extending typed grading to them is a separate follow-up).
    @State private var typedGrading: Bool = false
    @State private var detailWord: SavedWord?
    // Note / JLPT / scope / direction / count, persisted under this activity's own key prefix.
    @StateObject private var options = LearnActivityOptions(activity: .flashcards)
    private let activity = LearnActivity.flashcards
    // Opt-in Japanese theme; switches the grading labels to Mincho また / わかった when on.
    @AppStorage(Theme.storageKey) private var japaneseTheme = false

    var body: some View {
        NavigationStack {
            Group {
                if wordsStore.words.isEmpty {
                    emptySavedState
                } else if session.isEmpty {
                    if sessionSource.isEmpty {
                        reviewHome
                    } else {
                        sessionCompleteState
                    }
                } else {
                    VStack(spacing: 16) {
                        sessionHeader
                        Spacer(minLength: 8)
                        cardStack
                        Spacer(minLength: 8)
                        bottomControl
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Flashcards", systemImage: "rectangle.on.rectangle.angled")
                ToolbarItem(placement: .topBarLeading) {
                    if isPresetSession {
                        Button {
                            if session.isEmpty {
                                dismiss()
                            } else {
                                showEndSessionConfirm = true
                            }
                        } label: {
                            Label(session.isEmpty ? "Close" : "End", systemImage: session.isEmpty ? "xmark" : "xmark.circle")
                        }
                    } else if session.isEmpty == false {
                        Button { showEndSessionConfirm = true } label: {
                            Label("End", systemImage: "xmark.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startSession() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(sessionSource.isEmpty)
                }
                if session.isEmpty == false || sessionSource.isEmpty == false {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Reshuffles and restarts. Sessions are always shuffled, so this is an
                        // action ("deal again"), not a mode.
                        Button { startSession() } label: {
                            Image(systemName: "shuffle")
                        }
                        .disabled(sessionSource.isEmpty)
                    }
                }
            }
            .alert("End session?", isPresented: $showEndSessionConfirm) {
                Button("End Session", role: .destructive) {
                    if isPresetSession {
                        dismiss()
                    } else {
                        endSessionEarly()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop the current review session.")
            }
        }
        .sheet(item: $detailWord) { word in
            WordDetailView(word: word, reading: nil, dictionaryStore: dictionaryStore, segmenter: segmenter, surfaceReadingData: surfaceReadingData, kanjiReadingFallback: kanjiReadingFallback)
                .environmentObject(wordsStore)
                .presentationDetents([.large])
        }
        // Suppress the Cards tab page dots and swipe-between-modes while reviewing.
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: session.isEmpty == false)
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: session.isEmpty == false)
        .onAppear {
            // Preset launch (from Coverage): seed the pool with the handed-in words and start once.
            if let presetWords, didAutoStartPreset == false {
                didAutoStartPreset = true
                isPresetSession = true
                if let presetCardCount { options.count = presetCardCount }
                sessionSource = presetWords
                startSession()
            }
        }
    }

    // Shows card number and running correct/again tallies.
    private var sessionHeader: some View {
        HStack {
            Text("\(progressNumerator) / \(sessionTotalCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                Label("\(sessionAgain)", systemImage: "arrow.uturn.left.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("\(sessionCorrect)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Stacks up to three upcoming cards so the queue depth is visible.
    // ForEach iterates words (not indices) so the dismissed card's view is removed by SwiftUI's
    // diff rather than reused with a new word — that reuse caused dragOffset to interpolate from
    // off-screen back to center, producing the visible "revert" between cards.
    private var cardStack: some View {
        let end = min(index + 3, session.count)
        let visible = Array(session[index..<end])
        let topID = session.indices.contains(index) ? session[index].canonicalEntryID : nil
        return ZStack {
            ForEach(visible.reversed()) { word in
                FlashcardCard(
                    word: word,
                    dictionaryStore: dictionaryStore,
                    isTop: word.canonicalEntryID == topID,
                    direction: resolvedDirection(for: word),
                    preferredNoteID: options.selectedNoteIDs.count == 1 ? options.selectedNoteIDs.first : nil,
                    showBack: $showBack,
                    dragOffset: $dragOffset,
                    isSwipingOut: $isSwipingOut,
                    swipeDirection: $swipeDirection,
                    // Swipe-to-grade is disabled for a card FlashcardTypedAnswerControl is grading —
                    // otherwise a stray horizontal swipe on the (still English-only) front face would
                    // grade the card before the user ever typed an answer. Flip-to-peek still works;
                    // that's no worse than self-graded mode already allowing a peek-then-swipe.
                    onKnow: { if isTypedGradingCard(word) == false { know() } },
                    onAgain: { if isTypedGradingCard(word) == false { again() } }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
    }

    // True when the current card should be graded via FlashcardTypedAnswerControl rather than
    // self-reported flip+Know/Again — typed grading is on, and this card's resolved direction is
    // production (English prompt, Japanese answer).
    private func isTypedGradingCard(_ word: SavedWord) -> Bool {
        typedGrading && resolvedDirection(for: word).answerIsMeaning == false
    }

    // The direction this card is being asked in: one of the session's ticked directions, chosen
    // per word and stable across re-renders, and narrowed to what the word can actually be asked
    // (a kana-only word is never handed a 漢字 direction). Falls back to かな→English when the
    // selection somehow leaves the word nothing — unreachable for a card that came through the
    // pool filter, which drops exactly those words.
    private func resolvedDirection(for word: SavedWord) -> QuestionDirection {
        options.directions.resolved(
            seed: word.canonicalEntryID,
            hasKanjiForm: LearnWordPool.estimatedHasKanjiForm(word, reviewStore: reviewStore)
        ) ?? .kanaToMeaning
    }

    // The typed-answer control when the current card calls for it, otherwise the usual
    // Again/Detail/Know row.
    @ViewBuilder
    private var bottomControl: some View {
        if session.indices.contains(index), isTypedGradingCard(session[index]) {
            let word = session[index]
            FlashcardTypedAnswerControl(
                word: word,
                dictionaryStore: dictionaryStore,
                direction: resolvedDirection(for: word),
                onGraded: { correct, gradedDirection, gradedHasKanjiForm in
                    if correct {
                        know(direction: gradedDirection, hasKanjiForm: gradedHasKanjiForm)
                    } else {
                        again(direction: gradedDirection, hasKanjiForm: gradedHasKanjiForm)
                    }
                }
            )
            .id(word.canonicalEntryID)
        } else {
            controls
        }
    }

    // Again / Detail / Know buttons shown while a session is active.
    private var controls: some View {
        HStack(spacing: 16) {
            Button { again() } label: {
                HStack {
                    Image(systemName: "arrow.uturn.left.circle")
                    Text(japaneseTheme ? "また" : "Again")
                        .font(japaneseTheme ? .custom("HiraMinProN-W6", size: 16) : nil)
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer()

            Button {
                guard session.isEmpty == false else { return }
                detailWord = session[index]
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            Spacer()

            Button { know() } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(japaneseTheme ? "わかった" : "Know")
                        .font(japaneseTheme ? .custom("HiraMinProN-W6", size: 16) : nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    // 1-based card position for display; avoids showing 0 at the very end.
    private var progressNumerator: Int {
        guard sessionTotalCount > 0 else { return 0 }
        return reviewedCount + 1
    }

    // Shown when the user has no saved words yet.
    private var emptySavedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book").font(.largeTitle)
            Text("No saved words").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Shown after the last card in a session is resolved.
    private var sessionCompleteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle)
            Text("Session complete").font(.headline)

            HStack(spacing: 16) {
                Label("\(sessionCorrect) correct", systemImage: "checkmark.circle.fill")
                Label("\(sessionAgain) again", systemImage: "arrow.uturn.left.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let acc = reviewStore.lifetimeAccuracy {
                Text("Lifetime accuracy: \(Int((acc * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Lifetime accuracy: —")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button { startSession() } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(sessionSource.isEmpty)

            Button {
                if isPresetSession {
                    dismiss()
                } else {
                    session = []; sessionSource = []
                }
            } label: {
                Label(isPresetSession ? "Done" : "Choose Different Cards", systemImage: isPresetSession ? "checkmark.circle" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The shared start screen, plus Flashcards' own typed-answer toggle.
    private var reviewHome: some View {
        LearnActivityHome(
            activity: activity,
            options: options,
            dictionaryStore: dictionaryStore,
            poolCount: eligibleWords().count,
            onStart: { startSessionFromHome() },
            extraSections: {
                Section {
                    Toggle("Typed answers", isOn: $typedGrading)
                }
            }
        )
    }

    // Words passing every filter and askable in at least one selected direction.
    private func eligibleWords() -> [SavedWord] {
        LearnWordPool.eligibleWords(
            in: wordsStore.words, options: options,
            reviewStore: reviewStore, dictionaryStore: dictionaryStore
        )
    }

    // Starts a fresh pass through sessionSource, resetting all counters.
    private func startSession() {
        guard sessionSource.isEmpty == false else {
            session = []; index = 0; showBack = false; dragOffset = .zero
            return
        }
        sessionCorrect = 0; sessionAgain = 0; reviewedCount = 0
        session = sessionSource
        session.shuffle()
        // A positive count caps the deck (after the shuffle, so a capped session is a random
        // subset); 0 / blank means run every card in the selection.
        if options.count > 0 { session = Array(session.prefix(options.count)) }
        sessionTotalCount = session.count
        index = 0; showBack = false; dragOffset = .zero
    }

    // Records an "again", appends the card to the back of the queue, and advances. `direction` and
    // `hasKanjiForm` override the surface-heuristic resolution — passed by
    // FlashcardTypedAnswerControl, which already fetched the word's live kanji/kana and so knows
    // both more precisely.
    private func again(direction overrideDirection: QuestionDirection? = nil, hasKanjiForm: Bool? = nil) {
        guard session.isEmpty == false else { return }
        sessionAgain += 1; reviewedCount += 1
        let w = session[index]
        reviewStore.recordAgain(
            for: w.canonicalEntryID,
            direction: overrideDirection ?? resolvedDirection(for: w),
            hasKanjiForm: hasKanjiForm ?? surfaceKanjiEvidence(for: w)
        )
        session.remove(at: index)
        session.append(w)
        if index >= session.count { index = session.count - 1 }
        showBack = false
    }

    // Records a "know", removes the card from the queue, and advances. See `again` re: `direction`.
    private func know(direction overrideDirection: QuestionDirection? = nil, hasKanjiForm: Bool? = nil) {
        guard session.isEmpty == false else { return }
        sessionCorrect += 1; reviewedCount += 1
        let w = session[index]
        reviewStore.recordCorrect(
            for: w.canonicalEntryID,
            direction: overrideDirection ?? resolvedDirection(for: w),
            hasKanjiForm: hasKanjiForm ?? surfaceKanjiEvidence(for: w)
        )
        session.remove(at: index)
        if session.isEmpty { return }
        if index >= session.count { index = max(0, session.count - 1) }
        showBack = false
    }

    // What the saved surface alone can prove about the word having a kanji form. Kanji in the
    // surface is conclusive; its absence is not (a word saved as ありがとう may still have the
    // headword 有難う), so that case reports nil — unknown — rather than claiming kana-only and
    // wrongly relaxing the word's promotion bar. The typed-answer control, which does fetch the
    // headword, passes the authoritative answer instead.
    private func surfaceKanjiEvidence(for word: SavedWord) -> Bool? {
        ScriptClassifier.containsKanji(word.surface) ? true : nil
    }

    // Builds the session queue from the current scope selection and kicks off the session.
    private func startSessionFromHome() {
        sessionSource = eligibleWords()
        startSession()
    }

    // Clears all session state, returning to the home screen.
    private func endSessionEarly() {
        session = []; sessionSource = []
        index = 0; showBack = false; dragOffset = .zero
        isSwipingOut = false; swipeDirection = 0
        sessionCorrect = 0; sessionAgain = 0
        sessionTotalCount = 0; reviewedCount = 0
    }

}

// Multiselect dropdown scoping the session to saved words from one or more notes.
// An empty selection ("None") means no note filter — all saved words are eligible.
// Only notes that contain at least one saved word are listed.
// Internal (not private) so the multiple-choice study mode can reuse the same picker.
struct FlashcardNotePicker: View {
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var wordsStore: WordsStore
    @Binding var selectedNoteIDs: Set<UUID>

    var body: some View {
        let notes = notesWithSavedWords
        if notes.isEmpty {
            Text("No notes with saved words.").font(.footnote).foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Note")
                Spacer()
                Menu(summary(from: notes)) {
                    Button { selectedNoteIDs.removeAll() } label: {
                        if selectedNoteIDs.isEmpty {
                            Label("None", systemImage: "checkmark")
                        } else {
                            Text("None")
                        }
                    }
                    Divider()
                    ForEach(notes) { note in
                        Button {
                            if selectedNoteIDs.contains(note.id) {
                                selectedNoteIDs.remove(note.id)
                            } else {
                                selectedNoteIDs.insert(note.id)
                            }
                        } label: {
                            let title = note.title.isEmpty ? "Untitled" : note.title
                            if selectedNoteIDs.contains(note.id) {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            }
        }
    }

    // Notes that contain at least one saved word — the only ones worth showing in the filter.
    private var notesWithSavedWords: [Note] {
        var ids: Set<UUID> = []
        for word in wordsStore.words {
            for id in word.sourceNoteIDs { ids.insert(id) }
        }
        return notesStore.notes.filter { ids.contains($0.id) }
    }

    // Short label describing the current selection for the menu's trigger text.
    private func summary(from notes: [Note]) -> String {
        if selectedNoteIDs.isEmpty { return "None" }
        if selectedNoteIDs.count == 1,
           let id = selectedNoteIDs.first,
           let note = notes.first(where: { $0.id == id }) {
            return note.title.isEmpty ? "Untitled" : note.title
        }
        return "\(selectedNoteIDs.count) notes"
    }
}

// Multiselect dropdown scoping the session to saved words at one or more JLPT levels (N5–N1).
// An empty selection ("Any") means no level filter. Counts reflect saved words whose entry has
// that level in the dictionary's entry_jlpt_level map (unofficial estimates). Internal so
// Multiple Choice reuses it. Renders nothing when the dictionary carries no JLPT data at all.
struct FlashcardJLPTPicker: View {
    @EnvironmentObject private var wordsStore: WordsStore
    let dictionaryStore: DictionaryStore?
    @Binding var selectedLevels: Set<Int>

    var body: some View {
        // Hide entirely when no saved word has a known level — nothing to pick from.
        if anyLevelAvailable {
            HStack {
                Text("JLPT")
                Spacer()
                Menu(summary) {
                    Button { selectedLevels.removeAll() } label: {
                        if selectedLevels.isEmpty {
                            Label("Any", systemImage: "checkmark")
                        } else {
                            Text("Any")
                        }
                    }
                    Divider()
                    // N5 (easiest) first.
                    ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { level in
                        Button {
                            if selectedLevels.contains(level) {
                                selectedLevels.remove(level)
                            } else {
                                selectedLevels.insert(level)
                            }
                        } label: {
                            let title = "N\(level) (\(count(for: level)))"
                            if selectedLevels.contains(level) {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            }
        }
    }

    // Saved-word count whose entry sits at the given JLPT level.
    private func count(for level: Int) -> Int {
        wordsStore.words.filter { dictionaryStore?.jlptLevel(for: $0.canonicalEntryID) == level }.count
    }

    // True when at least one saved word has any known JLPT level.
    private var anyLevelAvailable: Bool {
        wordsStore.words.contains { dictionaryStore?.jlptLevel(for: $0.canonicalEntryID) != nil }
    }

    // Short label describing the current selection for the menu's trigger text.
    private var summary: String {
        if selectedLevels.isEmpty { return "Any" }
        return selectedLevels.sorted(by: >).map { "N\($0)" }.joined(separator: ", ")
    }
}
