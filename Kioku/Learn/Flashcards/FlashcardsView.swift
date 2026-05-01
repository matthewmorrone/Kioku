import SwiftUI

// Live dictionary content for one flashcard, fetched asynchronously from DictionaryStore.
// `meanings` carries one entry per selected sense so the back face can render them stacked;
// it falls back to the entry's first sense when the saved word has no explicit selection.
private struct FlashcardLiveContent {
    let surface: String
    let kana: String?
    let meanings: [String]
}

// Swipe vs. flip gesture disambiguation state for a card drag.
private enum FlashcardGestureMode {
    case undecided
    case swipe
    case flip
}

// Which physical face of the card is showing.
private enum FlashcardCardFace {
    case front
    case back
}

// Which side of each card is the prompt vs. the answer.
private enum FlashcardCardDirection: String, CaseIterable, Identifiable {
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

// Renders one card in the stack with 3D flip and swipe-to-grade gestures.
// Major sections: card face (front/back with lighting gradients), gesture handler, swipe-out animation.
private struct FlashcardCard: View {
    let word: SavedWord
    let dictionaryStore: DictionaryStore?
    let isTop: Bool
    let direction: FlashcardCardDirection
    let preferredNoteID: UUID?
    @Binding var showBack: Bool
    @Binding var dragOffset: CGSize
    @Binding var isSwipingOut: Bool
    @Binding var swipeDirection: Int
    let onKnow: () -> Void
    let onAgain: () -> Void

    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var liveContent: FlashcardLiveContent?
    @State private var gestureMode: FlashcardGestureMode = .undecided
    @State private var flipAngleDegrees: Double = 0
    @State private var flipStartAngleDegrees: Double = 0

    private let maxRotationDegrees: CGFloat = 10
    private let dismissDistance: CGFloat = 120
    private let dismissPredictedDistance: CGFloat = 180
    private let flipDistance: CGFloat = 110
    private let flipPredictedDistance: CGFloat = 160
    private let flipDragDistance: CGFloat = 220

    var body: some View {
        cardContent
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
            .contentShape(Rectangle())
            .offset(x: isTop ? dragOffset.width : 0, y: isTop ? dragOffset.height : 0)
            .rotationEffect(.degrees(isTop ? currentRotationDegrees : 0))
            .scaleEffect(isTop && dragOffset != .zero ? 1.03 : 1)
            .shadow(
                color: Color.black.opacity(isTop ? currentShadowOpacity : 0.08),
                radius: isTop ? (8 + 10 * dragProgress) : 8,
                x: 0,
                y: isTop ? (4 + 10 * dragProgress) : 4
            )
            .overlay(actionOverlays)
            .zIndex(isTop ? 10 : 0)
            .allowsHitTesting(isTop)
            .gesture(dragGesture)
            .onAppear {
                if isTop { flipAngleDegrees = showBack ? 180 : 0 }
            }
            .onChange(of: isTop) { _, newValue in
                if newValue { flipAngleDegrees = showBack ? 180 : 0 }
            }
            .onChange(of: showBack) { _, newValue in
                guard isTop, gestureMode != .flip else { return }
                flipAngleDegrees = newValue ? 180 : 0
            }
            // Task id includes both selection arrays so the lookup re-fires whenever the user
            // toggles a sense or a gloss from the word detail view.
            .task(id: liveContentTaskID) {
                liveContent = await resolveLiveContent()
            }
    }

    // Stable identity for the task that resolves liveContent — entry id followed by every
    // selected-sense id and every selected gloss ref. Recomputing fires .task again.
    private var liveContentTaskID: [Int64] {
        var key: [Int64] = [word.canonicalEntryID]
        key.append(contentsOf: word.selectedSenseIDs)
        for ref in word.selectedGlosses {
            key.append(ref.senseID)
            key.append(Int64(ref.glossIndex))
        }
        return key
    }

    // Resolves kana + glosses for this card's word directly from the dictionary store.
    // Each card owns its own fetch so display state cannot drift from any sibling-keyed cache.
    // The meanings list combines whole-sense selections (use sense's first gloss) with
    // gloss-level selections (use that exact gloss text); duplicates are dropped so a sense
    // selected and one of its glosses pinned doesn't render the same phrase twice.
    private func resolveLiveContent() async -> FlashcardLiveContent? {
        guard let store = dictionaryStore else { return nil }
        let entryID = word.canonicalEntryID
        let surface = word.surface
        let selectedSenseIDs = word.selectedSenseIDs
        let selectedGlosses = word.selectedGlosses
        return await Task.detached(priority: .utility) {
            guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
                return nil
            }
            let kana = data.entry.kanaForms.first?.text

            var sensesByID: [Int64: DictionaryEntrySense] = [:]
            for sense in data.entry.senses { sensesByID[sense.senseID] = sense }

            var meanings: [String] = []
            var seen: Set<String> = []

            func append(_ raw: String) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else { return }
                meanings.append(trimmed)
            }

            for senseID in selectedSenseIDs {
                if let first = sensesByID[senseID]?.glosses.first { append(first) }
            }
            for ref in selectedGlosses {
                if let sense = sensesByID[ref.senseID],
                   ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                    append(sense.glosses[ref.glossIndex])
                }
            }

            // Fallback: nothing selected (or selections didn't survive a dictionary rebuild)
            // — show the entry's first sense's first gloss, matching the original behavior.
            if meanings.isEmpty, let first = data.entry.senses.first?.glosses.first {
                append(first)
            }

            return FlashcardLiveContent(surface: surface, kana: kana, meanings: meanings)
        }.value
    }

    private var dragProgress: CGFloat {
        guard isTop else { return 0 }
        return min(1, abs(dragOffset.width) / 140)
    }

    private var currentRotationDegrees: Double {
        guard isTop else { return 0 }
        return Double(max(-maxRotationDegrees, min(maxRotationDegrees, dragOffset.width / 22)))
    }

    private var currentShadowOpacity: Double { 0.14 + Double(0.18 * dragProgress) }

    @ViewBuilder
    private var cardContent: some View {
        let angle = isTop ? flipAngleDegrees : 0
        let radians = angle * .pi / 180
        let isFrontVisible = cos(radians) >= 0
        let tilt = abs(sin(radians))
        let perspective: CGFloat = reduceMotion ? 1 / 650 : 1 / 320
        let roll = reduceMotion ? 0.0 : (6 * tilt)

        ZStack {
            cardFace(flipAngle: angle, face: .front) { frontFace }
                .opacity(isFrontVisible ? 1 : 0)
                .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: perspective)
                .rotation3DEffect(.degrees(roll), axis: (x: 0, y: 1, z: 0), perspective: perspective)

            cardFace(flipAngle: angle, face: .back) { backFace }
                .opacity(isFrontVisible ? 0 : 1)
                .rotation3DEffect(.degrees(angle - 180), axis: (x: 1, y: 0, z: 0), perspective: perspective)
                .rotation3DEffect(.degrees(-roll), axis: (x: 0, y: 1, z: 0), perspective: perspective)
        }
    }

    // Applies lighting gradients to simulate a physical card flipping in light.
    private func cardFace<Content: View>(
        flipAngle: Double,
        face: FlashcardCardFace,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let radians = flipAngle * .pi / 180
        let tilt = abs(sin(radians))
        let glossStrength = reduceMotion ? 0.0 : (0.03 + 0.10 * tilt)
        let highlightFromTop = face == .front

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.02 + 0.07 * tilt), Color.clear],
                        startPoint: highlightFromTop ? .top : .bottom,
                        endPoint: .center
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.03 + 0.12 * tilt)],
                        startPoint: .center,
                        endPoint: highlightFromTop ? .bottom : .top
                    )
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.white.opacity(glossStrength), Color.clear],
                        center: face == .front ? .topLeading : .topTrailing,
                        startRadius: 0, endRadius: 180
                    )
                    .blendMode(.screen)
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.black.opacity(0.05 + 0.07 * tilt), Color.clear],
                        center: face == .front ? .bottomTrailing : .bottomLeading,
                        startRadius: 0, endRadius: 220
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.06 + 0.10 * tilt), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

            content()
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: 320)
        }
    }

    @ViewBuilder
    private var frontFace: some View {
        let displaySurface = displaySurfaceForCard()
        let displayKana = displayKanaForCard(displaySurface: displaySurface)
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            switch direction {
            case .kanjiToKana:
                Text(displaySurface)
                    .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            case .kanaToEnglish:
                // Hold off rendering kanji as a fallback while the dictionary lookup is still
                // in flight — flashing the kanji would defeat the kana → English drill.
                if let displayKana, displayKana.isEmpty == false {
                    Text(displayKana)
                        .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                } else if liveContent != nil {
                    Text(displaySurface)
                        .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                }
            case .noteToEnglish:
                // Show the form the user saw in the source note exactly (kanji, kana, inflected
                // — whatever the saved surface is). Drills recognition of the encountered form
                // rather than the dictionary form.
                Text(displaySurface)
                    .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var backFace: some View {
        let displaySurface = displaySurfaceForCard()
        let displayKana = displayKanaForCard(displaySurface: displaySurface)
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            switch direction {
            case .kanjiToKana:
                if let kana = displayKana, kana.isEmpty == false {
                    Text(kana).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                } else if isKanaOnly(displaySurface) {
                    Text(displaySurface).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                } else {
                    Text("—").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                }
            case .kanaToEnglish, .noteToEnglish:
                let meanings = liveContent?.meanings ?? []
                if meanings.isEmpty == false {
                    VStack(spacing: 8) {
                        ForEach(meanings, id: \.self) { meaning in
                            Text(meaning)
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                    }
                } else {
                    Text("—").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // Prefers showing the form that appears in the source note to give reading context.
    // Falls back to the SavedWord's stored surface so the card always shows something
    // immediately, even before the dictionary lookup resolves.
    private func displaySurfaceForCard() -> String {
        let liveSurface = liveContent?.surface.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let surface = liveSurface.isEmpty ? word.surface : liveSurface
        guard surface.isEmpty == false else { return word.surface }

        let noteID = preferredNoteID ?? word.sourceNoteIDs.first
        guard let noteID,
              let noteText = notesStore.notes.first(where: { $0.id == noteID })?.content,
              noteText.isEmpty == false
        else { return surface }

        if noteText.contains(surface) { return surface }
        if let kana = liveContent?.kana?.trimmingCharacters(in: .whitespacesAndNewlines),
           kana.isEmpty == false,
           noteContains(noteText, candidate: kana) {
            return kana
        }
        return surface
    }

    // Returns the kana reading to show below the headword on a card, or nil when the surface is already pure kana.
    private func displayKanaForCard(displaySurface: String) -> String? {
        if let kana = liveContent?.kana?.trimmingCharacters(in: .whitespacesAndNewlines),
           kana.isEmpty == false { return kana }
        return isKanaOnly(displaySurface) ? displaySurface : nil
    }

    // Checks containment after folding katakana → hiragana so variant kana spellings match.
    private func noteContains(_ noteText: String, candidate: String) -> Bool {
        if noteText.contains(candidate) { return true }
        let folded = noteText.applyingTransform(.hiraganaToKatakana, reverse: true) ?? noteText
        let foldedCandidate = candidate.applyingTransform(.hiraganaToKatakana, reverse: true) ?? candidate
        return folded.contains(foldedCandidate)
    }

    // Determines whether a surface form is composed entirely of kana so a redundant reading line is suppressed.
    private func isKanaOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.isEmpty == false else { return false }
        return t.unicodeScalars.allSatisfy { s in
            (0x3040...0x309F).contains(s.value) ||
            (0x30A0...0x30FF).contains(s.value) ||
            s.value == 0x30FC ||
            (0xFF66...0xFF9F).contains(s.value)
        }
    }

    @ViewBuilder
    private var actionOverlays: some View {
        if isTop {
            Group {
                Text("Again").font(.headline).padding(8)
                    .background(Color.red.opacity(0.2)).cornerRadius(8)
                    .opacity(max(0, min(1, -dragOffset.width / 100)))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Text("Know").font(.headline).padding(8)
                    .background(Color.green.opacity(0.2)).cornerRadius(8)
                    .opacity(max(0, min(1, dragOffset.width / 100)))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isTop else { return }
                if gestureMode == .undecided {
                    let t = value.translation
                    if abs(t.width) > 12 || abs(t.height) > 12 {
                        gestureMode = abs(t.width) >= abs(t.height) ? .swipe : .flip
                        if gestureMode == .flip { flipStartAngleDegrees = flipAngleDegrees }
                    }
                }
                switch gestureMode {
                case .swipe, .undecided:
                    dragOffset = value.translation
                case .flip:
                    dragOffset = CGSize(width: 0, height: value.translation.height * 0.08)
                    let delta = (-value.translation.height / flipDragDistance) * 180
                    flipAngleDegrees = flipStartAngleDegrees + Double(delta)
                }
            }
            .onEnded { value in
                guard isTop else { return }
                switch gestureMode {
                case .flip:
                    finishFlip(translation: value.translation, predicted: value.predictedEndTranslation)
                case .swipe, .undecided:
                    handleDragEnd(translation: value.translation, predicted: value.predictedEndTranslation)
                }
                gestureMode = .undecided
            }
    }

    // Decides whether a horizontal drag should dismiss the card and in which direction, or spring it back.
    private func handleDragEnd(translation: CGSize, predicted: CGSize) {
        let dx = translation.width
        let predictedDx = predicted.width
        guard abs(dx) > dismissDistance || abs(predictedDx) > dismissPredictedDistance else {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) { dragOffset = .zero }
            return
        }
        let dir: Int = (predictedDx != 0 ? predictedDx > 0 : dx > 0) ? 1 : -1
        swipeOut(direction: dir) { dir > 0 ? onKnow() : onAgain() }
    }

    // Commits or cancels a vertical flip gesture, snapping the card to the nearest face.
    private func finishFlip(translation: CGSize, predicted: CGSize) {
        let dy = translation.height
        let predictedDy = predicted.height
        let shouldCommit = abs(dy) > flipDistance || abs(predictedDy) > flipPredictedDistance
        let directionStep: Int = ((predictedDy != 0 ? predictedDy : dy) < 0) ? 1 : -1
        let startIndex = Int((flipStartAngleDegrees / 180).rounded())
        let targetIndex = shouldCommit ? (startIndex + directionStep) : startIndex
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            flipAngleDegrees = Double(targetIndex) * 180
            dragOffset = .zero
        }
        showBack = (abs(targetIndex) % 2) == 1
    }

    // Animates the card flying off screen, then fires the completion callback to update session state.
    // The post-flight state swap (advance session, reset dragOffset) runs inside an animation-less
    // Transaction so SwiftUI cannot interpolate dragOffset back to center — that interpolation was
    // the visual "revert" between the dismissed card and the next card.
    private func swipeOut(direction dir: Int, completion: @escaping () -> Void) {
        let offX: CGFloat = CGFloat(dir) * 720
        let remaining = abs(offX - dragOffset.width)
        let duration = reduceMotion ? 0.01 : min(0.50, max(0.28, Double(remaining / 1600)))
        isSwipingOut = true; swipeDirection = dir
        withAnimation(.easeOut(duration: duration)) {
            dragOffset = CGSize(width: offX, height: dragOffset.height * 0.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withTransaction(Transaction(animation: nil)) {
                completion()
                showBack = false
                dragOffset = .zero
            }
            isSwipingOut = false
            swipeDirection = 0
        }
    }
}
