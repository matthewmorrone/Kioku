import SwiftUI

// Restricted to the 4 QuestionDirection cases whose answer is Japanese script (kanji or kana) —
// the only ones AnswerScorer can grade reliably. kanjiToMeaning/kanaToMeaning are deliberately
// excluded: an English answer has too many valid phrasings to fuzzy-match without an LLM (same
// reasoning FlashcardsView's typed-answer mode uses to restrict itself to englishToJapanese).
// `nonisolated` (like `QuestionDirection`) since it's a pure, stateless mapping — callable from any
// context, including plain (non-`@MainActor`) unit tests.
nonisolated enum FillInBlankDirection: String, CaseIterable, Identifiable {
    case kanjiToKana = "漢字 → かな"
    case kanaToKanji = "かな → 漢字"
    case meaningToKanji = "English → 漢字"
    case meaningToKana = "English → かな"
    case mixed = "Mixed"
    var id: String { rawValue }

    private static let mixedOptions: [QuestionDirection] = [.kanjiToKana, .kanaToKanji, .meaningToKanji, .meaningToKana]

    // Resolves `.mixed` to a concrete direction deterministically per item, so a question doesn't
    // change shape between re-renders. `seed` is typically the word's entry id.
    func resolved(seed: Int64) -> QuestionDirection {
        switch self {
        case .kanjiToKana: return .kanjiToKana
        case .kanaToKanji: return .kanaToKanji
        case .meaningToKanji: return .meaningToKanji
        case .meaningToKana: return .meaningToKana
        case .mixed:
            let count = Self.mixedOptions.count
            let index = Int(seed % Int64(count) + Int64(count)) % count
            return Self.mixedOptions[index]
        }
    }
}

// One assembled question: a prompt, the correct Japanese-script answer, and the direction it
// exercises — parallel to MultipleChoiceQuestion, but graded by typing instead of picking.
struct FillInBlankQuestion: Identifiable {
    let id: Int64
    let prompt: String
    let correct: String
    let direction: QuestionDirection
}

// Renders the fill-in-the-blank study mode: type the answer instead of picking it (Multiple
// Choice) or flipping a card (Flashcards) — a dedicated, always-typed production drill. Modeled on
// MultipleChoiceView's scope/note/JLPT pickers and session flow, but grades via AnswerScorer.
// Major sections: toolbar, question header, prompt + text field, review home form, summary.
struct FillInBlankView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @State private var questions: [FillInBlankQuestion] = []
    @State private var index: Int = 0
    @State private var typedAnswer: String = ""
    @State private var verdict: AnswerScorer.Verdict?
    @State private var sessionActive: Bool = false
    @State private var isResolving: Bool = false
    @FocusState private var isFocused: Bool

    @State private var sessionCorrect: Int = 0
    @State private var sessionWrong: Int = 0

    @State private var direction: FillInBlankDirection = .mixed
    // When on, blanks a real sentence from one of the word's source notes (see
    // SentenceBlankResolver) instead of asking for the bare word. Only words whose source note
    // still contains their exact surface are eligible, so this can shrink the word pool.
    @State private var sentenceContext: Bool = false
    @State private var scope: FlashcardScope = .all
    @State private var selectedNoteIDs: Set<UUID> = []
    // JLPT levels (N-number 5…1) to include; empty means no level filter. ANDs with scope + notes.
    @State private var selectedJLPTLevels: Set<Int> = []
    // Cap on how many questions a quiz runs. 0 (empty field) means "all available".
    @State private var questionCount: Int = 20

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
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Fill in the Blank", systemImage: "square.and.pencil")
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

    // The prompt headline plus the typed-answer field, or the verdict once checked.
    private var questionCard: some View {
        let question = questions[index]
        return VStack(spacing: 24) {
            Text(question.prompt)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let verdict {
                feedback(for: verdict, correct: question.correct)
            } else {
                TextField("Type the answer", text: $typedAnswer)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .onSubmit { check(question: question) }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button { check(question: question) } label: {
                    Label("Check", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { isFocused = true }
    }

    // Correct/incorrect result plus a Next/Finish button, replacing the text field once checked.
    @ViewBuilder
    private func feedback(for verdict: AnswerScorer.Verdict, correct: String) -> some View {
        VStack(spacing: 12) {
            Label(
                verdict.isCorrect ? "Correct" : "Incorrect — \(correct)",
                systemImage: verdict.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(verdict.isCorrect ? .green : .red)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Button { advance() } label: {
                Label(index + 1 >= questions.count ? "Finish" : "Next", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Grades the typed answer against the current question and records it against ReviewStore.
    private func check(question: FillInBlankQuestion) {
        guard typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        let result = AnswerScorer.grade(input: typedAnswer, expected: question.correct)
        verdict = result
        isFocused = false
        if result.isCorrect {
            sessionCorrect += 1
            reviewStore.recordCorrect(for: question.id, direction: question.direction)
        } else {
            sessionWrong += 1
            reviewStore.recordAgain(for: question.id, direction: question.direction)
        }
    }

    // Clears the answer field and verdict, and advances to the next question (or the summary).
    private func advance() {
        typedAnswer = ""
        verdict = nil
        index += 1
        isFocused = true
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
        let candidates = wordsMatchingSelection()
        let matchingWords = sentenceContext ? sentenceEligibleWords(candidates) : candidates
        let matchingCount = matchingWords.count
        let minWords = 1
        return LearnHomeForm(
            startTitle: "Start Quiz",
            startEnabled: matchingCount >= minWords,
            onStart: { startSessionFromHome() }
        ) {
            Section {
                FlashcardNotePicker(selectedNoteIDs: $selectedNoteIDs)
                FlashcardJLPTPicker(dictionaryStore: dictionaryStore, selectedLevels: $selectedJLPTLevels)
            }

            Section {
                Toggle("Sentence context", isOn: $sentenceContext)
                Text("Blanks a real sentence from your notes instead of asking for a bare word. Only words whose saved note still contains their exact surface are eligible — the count below reflects that when this is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // The direction picker doesn't apply once the sentence itself supplies the context —
            // sentence-context questions always ask for the exact surface that appeared, with the
            // direction inferred from its script (see buildSentenceQuestions).
            if sentenceContext == false {
                Section {
                    Picker("Direction", selection: $direction) {
                        ForEach(FillInBlankDirection.allCases) { d in Text(d.rawValue).tag(d) }
                    }
                    .pickerStyle(.menu)
                    Text("Only directions with a kanji/kana answer are offered — a typed English answer has too many valid phrasings to grade reliably.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                        .foregroundStyle(matchingCount < minWords ? .red : .primary)
                    if matchingCount < minWords {
                        Text("No words match this selection")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    // Resolves the question pool asynchronously, then activates the session. When sentence context
    // is on, the word pool is narrowed to words with a resolvable sentence blank first, so the
    // session only ever contains words the "Words in selection" count already promised.
    private func startSessionFromHome() {
        let candidates = wordsMatchingSelection()
        startSession(with: sentenceContext ? sentenceEligibleWords(candidates) : candidates)
    }

    // Builds and activates a session over an explicit word set.
    private func startSession(with words: [SavedWord]) {
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        typedAnswer = ""
        verdict = nil
        questions = []
        let dir = direction
        let limit = questionCount
        let useSentenceContext = sentenceContext
        let notes = notesStore.notes
        Task {
            let built: [FillInBlankQuestion]
            if useSentenceContext {
                built = buildSentenceQuestions(from: words, notes: notes)
            } else {
                let items = await resolveItems(for: words)
                built = buildQuestions(from: items, direction: dir)
            }
            // A positive limit caps the quiz; 0 (or blank field) means quiz everything.
            questions = limit > 0 ? Array(built.prefix(limit)) : built
            isResolving = false
        }
    }

    // Builds one question per item using the resolved direction's field pair. Items where the
    // prompt and answer would be identical (no distinct dictionary form to ask about) or the
    // answer resolves empty are skipped, mirroring MultipleChoiceView's equivalent guard.
    private func buildQuestions(
        from items: [MultipleChoiceItem],
        direction: FillInBlankDirection
    ) -> [FillInBlankQuestion] {
        var result: [FillInBlankQuestion] = []
        for item in items {
            let resolvedDirection = direction.resolved(seed: item.word.canonicalEntryID)
            let fields = resolvedDirection.fields
            let prompt = item.value(for: fields.prompt)
            let correct = item.value(for: fields.answer)
            guard prompt != correct, correct.isEmpty == false else { continue }
            result.append(FillInBlankQuestion(
                id: item.word.canonicalEntryID, prompt: prompt, correct: correct, direction: resolvedDirection
            ))
        }
        result.shuffle()
        return result
    }

    // Filters to words whose source notes still contain their exact surface — the same check
    // buildSentenceQuestions uses, surfaced here so the "Words in selection" count on the home
    // screen reflects reality before the user taps Start.
    private func sentenceEligibleWords(_ words: [SavedWord]) -> [SavedWord] {
        let notes = notesStore.notes
        return words.filter { SentenceBlankResolver.findBlank(for: $0, notes: notes) != nil }
    }

    // Builds one question per word with a resolvable sentence blank (see SentenceBlankResolver),
    // skipping any word whose source notes don't contain its surface. Direction is inferred from
    // the blanked surface's script — contains kanji → meaningToKanji evidence, kana-only →
    // meaningToKana — the same kana-only heuristic FlashcardsView already uses for its `.original`
    // form ambiguity, since a sentence blank doesn't map onto one of AnswerScorer's fixed
    // dictionary-field directions the way the standalone mode's questions do.
    private func buildSentenceQuestions(from words: [SavedWord], notes: [Note]) -> [FillInBlankQuestion] {
        var result: [FillInBlankQuestion] = []
        for word in words {
            guard let blank = SentenceBlankResolver.findBlank(for: word, notes: notes) else { continue }
            let blankDirection: QuestionDirection = ScriptClassifier.containsKanji(blank.surface)
                ? .meaningToKanji : .meaningToKana
            let prompt = "\(blank.before)＿＿＿\(blank.after)"
            result.append(FillInBlankQuestion(
                id: word.canonicalEntryID, prompt: prompt, correct: blank.surface, direction: blankDirection
            ))
        }
        result.shuffle()
        return result
    }

    // Clears all session state, returning to the home screen.
    private func endSession() {
        sessionActive = false
        isResolving = false
        questions = []
        index = 0
        typedAnswer = ""
        verdict = nil
        sessionCorrect = 0
        sessionWrong = 0
    }

    // Resolves each saved word to its Japanese surface, kana reading, and primary English gloss.
    // Each word's lookup runs as its own child task in a task group instead of one-at-a-time. Only
    // Sendable primitives (not SavedWord/MultipleChoiceItem) cross into resolveWordFields, and
    // results are correlated back to their word via entryID afterward — see
    // MultipleChoiceView.resolveItems, which this mirrors exactly, for why. Drops any word whose
    // dictionary lookup fails or yields no gloss so it can't produce a blank prompt; result order is
    // unconstrained since buildQuestions shuffles the final list anyway.
    private func resolveItems(for words: [SavedWord]) async -> [MultipleChoiceItem] {
        guard let store = dictionaryStore else { return [] }
        var wordsByID: [Int64: SavedWord] = [:]
        for word in words { wordsByID[word.canonicalEntryID] = word }

        let resolved = await withTaskGroup(of: ResolvedWordFields?.self) { group in
            for word in words {
                let entryID = word.canonicalEntryID
                let surface = word.surface
                let selectedSenseIDs = word.selectedSenseIDs
                let selectedGlosses = word.selectedGlosses
                group.addTask {
                    await Self.resolveWordFields(
                        store: store, entryID: entryID, surface: surface,
                        selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
                    )
                }
            }
            var results: [ResolvedWordFields] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }

        var items: [MultipleChoiceItem] = []
        for r in resolved {
            guard let word = wordsByID[r.entryID] else { continue }
            let surface = word.surface
            let gloss = r.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard gloss.isEmpty == false else { continue }
            let kanji = r.kanji?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usableKanji = (kanji?.isEmpty == false && kanji != surface) ? kanji : nil
            let kana = r.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usableKana = (kana?.isEmpty == false && kana != surface) ? kana : nil
            items.append(MultipleChoiceItem(
                word: word, original: surface, kanji: usableKanji, kana: usableKana, english: gloss
            ))
        }
        return items
    }

    // Resolves one word's kanji/kana/gloss from the dictionary. `nonisolated`, and takes only
    // Sendable primitives rather than SavedWord directly — see
    // MultipleChoiceView.resolveWordFields for why this matters (this project's default actor
    // isolation would otherwise make a plain `static func` implicitly @MainActor, silently
    // serializing every "concurrent" lookup back onto the main thread).
    private nonisolated static func resolveWordFields(
        store: DictionaryStore,
        entryID: Int64,
        surface: String,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef]
    ) async -> ResolvedWordFields? {
        guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
            return nil
        }
        var sensesByID: [Int64: DictionaryEntrySense] = [:]
        for sense in data.entry.senses { sensesByID[sense.senseID] = sense }

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

        let forms = WordFormResolver.kanjiAndKana(
            entry: data.entry, store: store, entryID: entryID,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
        )
        return ResolvedWordFields(entryID: entryID, english: gloss, kanji: forms.kanji, kana: forms.kana)
    }

    // Returns saved words filtered by the selected notes AND the active scope (all / due / wrong)
    // AND the selected JLPT levels (empty = any level).
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
