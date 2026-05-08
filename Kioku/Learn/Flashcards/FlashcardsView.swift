import SwiftUI

// Which side of each card is the prompt vs. the answer.
enum FlashcardCardDirection: String, CaseIterable, Identifiable {
    // Front shows the form the user encountered in the source note (saved surface, possibly
    // inflected) — useful for reading-comprehension drill.
    case noteToEnglish = "原文 → English"
    case kanaToEnglish = "かな → English"
    case kanjiToKana = "漢字 → かな"
    var id: String { rawValue }
}

// Renders the flashcard study mode: home configuration, active session, and session summary.
// Major sections: toolbar, session header, card stack, grading controls, review home form, session complete state.
struct FlashcardsView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @State private var session: [SavedWord] = []
    @State private var sessionSource: [SavedWord] = []
    @State private var index: Int = 0
    @State private var showBack: Bool = false
    @State private var shuffled: Bool = true

    @State private var dragOffset: CGSize = .zero
    @State private var isSwipingOut: Bool = false
    @State private var swipeDirection: Int = 0

    @State private var sessionCorrect: Int = 0
    @State private var sessionAgain: Int = 0
    @State private var sessionTotalCount: Int = 0
    @State private var reviewedCount: Int = 0

    @State private var showEndSessionConfirm: Bool = false
    @State private var direction: FlashcardCardDirection = .kanaToEnglish
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var detailWord: SavedWord?

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
                        controls
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                        Text("Flashcards")
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Flashcards")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if session.isEmpty == false {
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
                        Button {
                            shuffled.toggle()
                            if sessionSource.isEmpty == false { startSession() }
                        } label: {
                            Image(systemName: shuffled ? "shuffle" : "shuffle.slash")
                        }
                    }
                }
            }
            .alert("End session?", isPresented: $showEndSessionConfirm) {
                Button("End Session", role: .destructive) { endSessionEarly() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop the current review session.")
            }
        }
        .sheet(item: $detailWord) { word in
            WordDetailView(word: word, reading: nil, dictionaryStore: dictionaryStore, segmenter: segmenter)
                .environmentObject(wordsStore)
                .presentationDetents([.large])
        }
        // Suppress the Cards tab page dots and swipe-between-modes while reviewing.
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: session.isEmpty == false)
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: session.isEmpty == false)
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
                    direction: direction,
                    preferredNoteID: selectedNoteIDs.count == 1 ? selectedNoteIDs.first : nil,
                    showBack: $showBack,
                    dragOffset: $dragOffset,
                    isSwipingOut: $isSwipingOut,
                    swipeDirection: $swipeDirection,
                    onKnow: { know() },
                    onAgain: { again() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
    }

    // Again / Detail / Know buttons shown while a session is active.
    private var controls: some View {
        HStack(spacing: 16) {
            Button { again() } label: {
                HStack { Image(systemName: "arrow.uturn.left.circle"); Text("Again") }
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
                HStack { Image(systemName: "checkmark.circle.fill"); Text("Know") }
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
            Text("Save words from the Read tab to start reviewing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

            Button { session = []; sessionSource = [] } label: {
                Label("Choose Different Cards", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Scope / direction / shuffle pickers and session start button.
    private var reviewHome: some View {
        Form {
            Section {
                FlashcardNotePicker(selectedNoteIDs: $selectedNoteIDs)
            }

            Section {
                Picker("Direction", selection: $direction) {
                    ForEach(FlashcardCardDirection.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                let matchingCount = wordsMatchingSelection().count

                Button {
                    shuffled.toggle()
                } label: {
                    Label(
                        shuffled ? "Shuffle On" : "Shuffle Off",
                        systemImage: shuffled ? "shuffle" : "shuffle.slash"
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cards in selection").font(.caption).foregroundStyle(.secondary)
                    Text("\(matchingCount)")
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(matchingCount == 0 ? .red : .primary)
                    if matchingCount == 0 {
                        Text("No cards match this selection").font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)

                Button { startSessionFromHome() } label: {
                    Label("Start Flashcards", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matchingCount == 0)
            }
        }
    }

    // Starts a fresh pass through sessionSource, resetting all counters.
    private func startSession() {
        guard sessionSource.isEmpty == false else {
            session = []; index = 0; showBack = false; dragOffset = .zero
            return
        }
        sessionCorrect = 0; sessionAgain = 0; reviewedCount = 0
        session = sessionSource
        if shuffled { session.shuffle() }
        sessionTotalCount = session.count
        index = 0; showBack = false; dragOffset = .zero
    }

    // Records an "again", appends the card to the back of the queue, and advances.
    private func again() {
        guard session.isEmpty == false else { return }
        sessionAgain += 1; reviewedCount += 1
        let w = session[index]
        reviewStore.recordAgain(for: w.canonicalEntryID)
        session.remove(at: index)
        session.append(w)
        if index >= session.count { index = session.count - 1 }
        showBack = false
    }

    // Records a "know", removes the card from the queue, and advances.
    private func know() {
        guard session.isEmpty == false else { return }
        sessionCorrect += 1; reviewedCount += 1
        reviewStore.recordCorrect(for: session[index].canonicalEntryID)
        session.remove(at: index)
        if session.isEmpty { return }
        if index >= session.count { index = max(0, session.count - 1) }
        showBack = false
    }

    // Builds the session queue from the current scope selection and kicks off the session.
    private func startSessionFromHome() {
        sessionSource = wordsMatchingSelection()
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

    // Returns saved words filtered by the selected notes; an empty selection means no filter.
    private func wordsMatchingSelection() -> [SavedWord] {
        let base = wordsStore.words
        guard selectedNoteIDs.isEmpty == false else { return base }
        return base.filter { word in
            word.sourceNoteIDs.contains(where: { selectedNoteIDs.contains($0) })
        }
    }

}

// Multiselect dropdown scoping the session to saved words from one or more notes.
// An empty selection ("None") means no note filter — all saved words are eligible.
// Only notes that contain at least one saved word are listed.
private struct FlashcardNotePicker: View {
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
