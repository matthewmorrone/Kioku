import SwiftUI

// A saved word resolved to its display strings on every side, used to build questions and to
// supply distractors. Resolved once at session start so per-question assembly stays synchronous.
// `kanji`/`kana` are nil when the dictionary has no distinct kanji headword / reading.
struct MultipleChoiceItem: Identifiable {
    let word: SavedWord
    let original: String     // saved/encountered surface (原文)
    let kanji: String?       // dictionary kanji headword (漢字)
    let kana: String?        // kana reading (かな)
    let english: String
    var id: Int64 { word.canonicalEntryID }

    // The Japanese string to display for the chosen form, falling back to the original surface
    // when the requested kanji headword / kana reading isn't available.
    func japanese(for form: StudyJapaneseForm) -> String {
        switch form {
        case .original: return original
        case .kanji: return kanji ?? original
        case .kana: return kana ?? original
        }
    }
}

// One assembled question: a prompt, the shuffled options (including the correct one), and which
// option is correct. Options are plain strings so comparison and feedback colouring are trivial.
struct MultipleChoiceQuestion: Identifiable {
    let id: Int64
    let prompt: String
    let options: [String]
    let correct: String
}

// Renders the multiple-choice study mode: home configuration, active quiz, and summary.
// Modeled on FlashcardsView (same scope/note pickers, same ReviewStore grading) but objective:
// a tap is unambiguously right or wrong, so it grades automatically instead of self-assessment.
// Major sections: toolbar, question header, prompt + option buttons, review home form, summary.
struct MultipleChoiceView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @State private var questions: [MultipleChoiceQuestion] = []
    @State private var index: Int = 0
    @State private var selected: String?
    @State private var sessionActive: Bool = false
    @State private var isResolving: Bool = false

    @State private var sessionCorrect: Int = 0
    @State private var sessionWrong: Int = 0

    @State private var direction: StudyDirection = .japaneseToEnglish
    @State private var japaneseForm: StudyJapaneseForm = .kanji
    @State private var scope: FlashcardScope = .all
    @State private var selectedNoteIDs: Set<UUID> = []
    // JLPT levels (N-number 5…1) to include; empty means no level filter. ANDs with scope + notes.
    @State private var selectedJLPTLevels: Set<Int> = []
    // Cap on how many questions a quiz runs. 0 (empty field) means "all available".
    @State private var questionCount: Int = 20

    // Number of answer choices presented per question (correct + up to three distractors).
    private let optionCount = 4

    var body: some View {
        NavigationStack {
            Group {
                if wordsStore.words.isEmpty {
                    emptySavedState
                } else if sessionActive == false {
                    reviewHome
                } else if isResolving {
                    resolvingState
                } else if index >= questions.count {
                    sessionCompleteState
                } else {
                    VStack(spacing: 16) {
                        sessionHeader
                        Spacer(minLength: 8)
                        questionCard
                        Spacer(minLength: 8)
                        nextControl
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Multiple Choice", systemImage: "checklist")
                ToolbarItem(placement: .topBarLeading) {
                    if sessionActive {
                        Button { endSession() } label: {
                            Label("End", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
        // Suppress the Learn tab page dots and swipe-between-modes while a quiz is in progress.
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: sessionActive)
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: sessionActive)
    }

    // Shows question position and running correct/wrong tallies.
    private var sessionHeader: some View {
        HStack {
            Text("\(min(index + 1, questions.count)) / \(questions.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                Label("\(sessionWrong)", systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("\(sessionCorrect)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // The prompt headline plus the stack of tappable answer options.
    private var questionCard: some View {
        let question = questions[index]
        return VStack(spacing: 24) {
            Text(question.prompt)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                ForEach(question.options, id: \.self) { option in
                    optionButton(option, correct: question.correct)
                }
            }
        }
    }

    // One answer option. Before answering it's a neutral filled capsule; after answering the
    // correct option turns green (✓) and a wrong pick turns red (✗), while the rest fade. Feedback
    // is painted with an explicit background/foreground (not `.tint`) so it survives the answered
    // state — a `.disabled` button greys out and would hide the colours. Re-taps are blocked via
    // `allowsHitTesting` instead, which has no dimming side effect.
    private func optionButton(_ option: String, correct: String) -> some View {
        Button { answer(option, correct: correct) } label: {
            HStack(spacing: 8) {
                Text(option)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let icon = optionIcon(option, correct: correct) {
                    Image(systemName: icon).font(.title3.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(optionBackground(option, correct: correct))
            .foregroundStyle(optionForeground(option, correct: correct))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(selected == nil)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    // Background fill for one option given the current answered state.
    private func optionBackground(_ option: String, correct: String) -> Color {
        guard let selected else { return Color(.secondarySystemBackground) }
        if option == correct { return .green }
        if option == selected { return .red }
        return Color(.secondarySystemBackground).opacity(0.5)
    }

    // Label/icon colour for one option: white on the green/red result fills, primary otherwise.
    private func optionForeground(_ option: String, correct: String) -> Color {
        guard let selected else { return .primary }
        if option == correct || option == selected { return .white }
        return .secondary
    }

    // The trailing icon for one option after answering: ✓ on the correct answer, ✗ on a wrong pick.
    private func optionIcon(_ option: String, correct: String) -> String? {
        guard let selected else { return nil }
        if option == correct { return "checkmark.circle.fill" }
        if option == selected { return "xmark.circle.fill" }
        return nil
    }

    // Next button (after answering) advances to the following question or the summary.
    @ViewBuilder
    private var nextControl: some View {
        if selected != nil {
            Button { advance() } label: {
                Label(index + 1 >= questions.count ? "Finish" : "Next",
                      systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            // Reserve the space so options don't jump when the Next button appears.
            Color.clear.frame(height: 44)
        }
    }

    // Shown while the dictionary lookups that build the question pool are in flight.
    private var resolvingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing questions…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Shown when the user has no saved words yet.
    private var emptySavedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book").font(.largeTitle)
            Text("No saved words").font(.headline)
            Text("Save words from the Read tab to start quizzing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Shown after the last question is answered.
    private var sessionCompleteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle)
            Text("Quiz complete").font(.headline)

            let total = sessionCorrect + sessionWrong
            HStack(spacing: 16) {
                Label("\(sessionCorrect) correct", systemImage: "checkmark.circle.fill")
                Label("\(sessionWrong) wrong", systemImage: "xmark.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if total > 0 {
                Text("This quiz: \(Int((Double(sessionCorrect) / Double(total) * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button { startSessionFromHome() } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button { endSession() } label: {
                Label("Choose Different Cards", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Note / direction / scope / count pickers and the start button, on the shared scaffold.
    private var reviewHome: some View {
        let matchingCount = wordsMatchingSelection().count
        return LearnHomeForm(
            startTitle: "Start Quiz",
            startEnabled: matchingCount >= optionCount,
            onStart: { startSessionFromHome() }
        ) {
            Section {
                FlashcardNotePicker(selectedNoteIDs: $selectedNoteIDs)
                FlashcardJLPTPicker(dictionaryStore: dictionaryStore, selectedLevels: $selectedJLPTLevels)
            }

            Section {
                Picker("Direction", selection: $direction) {
                    ForEach(StudyDirection.allCases) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.menu)

                Picker("Japanese", selection: $japaneseForm) {
                    ForEach(StudyJapaneseForm.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Scope", selection: $scope) {
                    ForEach(FlashcardScope.allCases) { s in
                        Text(scopeLabel(s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LearnCountField(label: "Questions", count: $questionCount)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Words in selection").font(.caption).foregroundStyle(.secondary)
                    Text("\(matchingCount)")
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(matchingCount < optionCount ? .red : .primary)
                    if matchingCount < optionCount {
                        Text("Need at least \(optionCount) words to build a quiz")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    // Resolves the question pool asynchronously, then activates the session.
    private func startSessionFromHome() {
        let words = wordsMatchingSelection()
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        selected = nil
        questions = []
        let dir = direction
        let form = japaneseForm
        let limit = questionCount
        Task {
            let items = await resolveItems(for: words)
            let built = buildQuestions(from: items, direction: dir, japaneseForm: form)
            // A positive limit caps the quiz; 0 (or blank field) means quiz everything.
            questions = limit > 0 ? Array(built.prefix(limit)) : built
            isResolving = false
        }
    }

    // Records the answer against ReviewStore (correct feeds SRS, wrong marks for relearn) and
    // freezes the option buttons so the feedback colours stay until the user taps Next.
    private func answer(_ option: String, correct: String) {
        guard selected == nil else { return }
        selected = option
        let id = questions[index].id
        if option == correct {
            sessionCorrect += 1
            reviewStore.recordCorrect(for: id)
        } else {
            sessionWrong += 1
            reviewStore.recordAgain(for: id)
        }
    }

    // Advances to the next question, or falls through to the summary when the pool is exhausted.
    private func advance() {
        selected = nil
        index += 1
    }

    // Clears all session state, returning to the home screen.
    private func endSession() {
        sessionActive = false
        isResolving = false
        questions = []
        index = 0
        selected = nil
        sessionCorrect = 0
        sessionWrong = 0
    }

    // Resolves each saved word to its Japanese surface, kana reading, and primary English gloss.
    // Mirrors the FlashcardCard lookup path: detached utility-priority work per word, dropping any
    // word whose dictionary lookup fails or yields no gloss so it can't produce a blank option.
    private func resolveItems(for words: [SavedWord]) async -> [MultipleChoiceItem] {
        guard let store = dictionaryStore else { return [] }
        var items: [MultipleChoiceItem] = []
        for word in words {
            let entryID = word.canonicalEntryID
            let surface = word.surface
            let selectedSenseIDs = word.selectedSenseIDs
            let selectedGlosses = word.selectedGlosses
            let resolved = await Task.detached(priority: .utility) { () -> (english: String, kanji: String?, kana: String?)? in
                guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
                    return nil
                }
                var sensesByID: [Int64: DictionaryEntrySense] = [:]
                for sense in data.entry.senses { sensesByID[sense.senseID] = sense }

                // Prefer the user's explicit sense/gloss selections, falling back to the entry's
                // first gloss — same precedence the flashcard back face uses.
                var gloss: String?
                for senseID in selectedSenseIDs where gloss == nil {
                    gloss = sensesByID[senseID]?.glosses.first
                }
                if gloss == nil {
                    for ref in selectedGlosses where gloss == nil {
                        if let sense = sensesByID[ref.senseID],
                           ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                            gloss = sense.glosses[ref.glossIndex]
                        }
                    }
                }
                if gloss == nil { gloss = data.entry.senses.first?.glosses.first }
                guard let gloss else { return nil }

                // Dictionary kanji headword (most common written form) and the reading that fits
                // the selected senses — the same calls the flashcard face uses.
                let kanji = data.entry.kanjiForms.first?.text
                let senseRestrictions = (try? store.fetchSenseRestrictions(entryID: entryID)) ?? []
                let kana = data.entry.preferredKana(
                    selectedSenseIDs: selectedSenseIDs,
                    selectedGlosses: selectedGlosses,
                    senseRestrictions: senseRestrictions
                )
                return (gloss, kanji, kana)
            }.value

            guard let resolved else { continue }
            let gloss = resolved.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard gloss.isEmpty == false else { continue }
            // Keep kanji/kana only when distinct and non-empty; otherwise nil so the form falls
            // back to the original surface.
            let kanji = resolved.kanji?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usableKanji = (kanji?.isEmpty == false && kanji != surface) ? kanji : nil
            let kana = resolved.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usableKana = (kana?.isEmpty == false && kana != surface) ? kana : nil
            items.append(MultipleChoiceItem(
                word: word, original: surface, kanji: usableKanji, kana: usableKana, english: gloss
            ))
        }
        return items
    }

    // Builds one question per item, drawing up to three distinct distractors from the other
    // items' answer-side strings. Items whose answer side has no distinct distractors at all are
    // dropped (can't form a meaningful choice). Under `.mixed`, each question independently picks
    // a direction. The final question list is shuffled.
    private func buildQuestions(
        from items: [MultipleChoiceItem],
        direction: StudyDirection,
        japaneseForm: StudyJapaneseForm
    ) -> [MultipleChoiceQuestion] {
        // Precomputed answer pools per direction so distractor selection stays O(1) per question.
        let englishStrings = Set(items.map(\.english))
        let japaneseStrings = Set(items.map { $0.japanese(for: japaneseForm) })

        var result: [MultipleChoiceQuestion] = []
        for item in items {
            // Resolve `.mixed` to a concrete direction per question (stable per entry id).
            let resolvedDirection = direction.resolved(seed: item.word.canonicalEntryID)

            let prompt: String
            let correct: String
            let pool: Set<String>
            switch resolvedDirection {
            case .japaneseToEnglish:
                prompt = item.japanese(for: japaneseForm)
                correct = item.english
                pool = englishStrings
            case .englishToJapanese:
                prompt = item.english
                correct = item.japanese(for: japaneseForm)
                pool = japaneseStrings
            case .mixed:
                // `resolved(seed:)` never returns `.mixed`; treat as Japanese→English defensively.
                prompt = item.japanese(for: japaneseForm)
                correct = item.english
                pool = englishStrings
            }

            var distractorPool = pool
            distractorPool.remove(correct)
            guard distractorPool.isEmpty == false else { continue }

            var distractors = Array(distractorPool)
            distractors.shuffle()
            distractors = Array(distractors.prefix(optionCount - 1))

            var options = distractors + [correct]
            options.shuffle()
            result.append(MultipleChoiceQuestion(
                id: item.word.canonicalEntryID,
                prompt: prompt,
                options: options,
                correct: correct
            ))
        }
        result.shuffle()
        return result
    }

    // Returns saved words filtered by the selected notes AND the active scope (all / due / wrong).
    private func wordsMatchingSelection() -> [SavedWord] {
        var base = wordsStore.words
        if selectedNoteIDs.isEmpty == false {
            base = base.filter { word in
                word.sourceNoteIDs.contains(where: { selectedNoteIDs.contains($0) })
            }
        }
        if selectedJLPTLevels.isEmpty == false {
            base = base.filter { word in
                guard let level = dictionaryStore?.jlptLevel(for: word.canonicalEntryID) else { return false }
                return selectedJLPTLevels.contains(level)
            }
        }
        switch scope {
        case .all:
            return base
        case .dueNow:
            return base.filter { reviewStore.isDue(id: $0.canonicalEntryID) }
        case .markedWrong:
            return base.filter { reviewStore.markedWrong.contains($0.canonicalEntryID) }
        }
    }

    // Builds the scope picker label, suffixing the count of words currently in that scope.
    private func scopeLabel(_ s: FlashcardScope) -> String {
        let base = wordsStore.words
        let scoped: [SavedWord]
        switch s {
        case .all:
            scoped = base
        case .dueNow:
            scoped = base.filter { reviewStore.isDue(id: $0.canonicalEntryID) }
        case .markedWrong:
            scoped = base.filter { reviewStore.markedWrong.contains($0.canonicalEntryID) }
        }
        return "\(s.label) (\(scoped.count))"
    }
}
