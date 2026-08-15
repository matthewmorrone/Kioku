import SwiftUI

// One assembled question: a prompt, the correct Japanese-script answer, and the direction it
// exercises — parallel to MultipleChoiceQuestion, but graded by typing instead of picking.
struct FillInBlankQuestion: Identifiable {
    let id: Int64
    let prompt: String
    let correct: String
    let direction: QuestionDirection
    // The accepted answers. One string for a Japanese answer; every gloss of the word's selected
    // senses when the answer is English, where "to eat" and "eat" are the same answer.
    let accepted: [String]
    // Whether the word has a kanji form, so answering can tell ReviewStore which promotion bar
    // applies (see `QuestionDirection.applicable`).
    let hasKanjiForm: Bool
}

// Renders the fill-in-the-blank study mode: type the answer instead of picking it (Multiple
// Choice) or flipping a card (Flashcards) — a dedicated, always-typed production drill. Modeled on
// MultipleChoiceView's scope/note/JLPT pickers and session flow, but grades via AnswerScorer.
// Major sections: toolbar, question header, prompt + text field, review home form, summary.
struct FillInBlankView: View {
    let dictionaryStore: DictionaryStore?
    // When non-nil, opens directly into a scoped session over these words (Coverage drill-down).
    var presetWords: [SavedWord]? = nil
    // The question cap the Coverage launch sheet's count field settled on; nil means "use the
    // saved default".
    var presetQuestionCount: Int? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @Environment(\.dismiss) private var dismiss

    @State private var questions: [FillInBlankQuestion] = []
    @State private var index: Int = 0
    @State private var typedAnswer: String = ""
    @State private var verdict: AnswerScorer.Verdict?
    // Set when the user gave up and revealed the answer rather than typing one. Graded the same as a
    // wrong answer (a revealed answer isn't recall), but labeled differently so the feedback doesn't
    // accuse them of getting something wrong that they never attempted.
    @State private var didReveal: Bool = false
    @State private var sessionActive: Bool = false
    @State private var isResolving: Bool = false
    // Guards the preset auto-start so it fires exactly once.
    @State private var didAutoStartPreset: Bool = false
    // True for the lifetime of a Coverage-launched sheet, where End closes the sheet rather than
    // returning to a home screen the user never came from.
    @State private var isPresetSession: Bool = false
    // The original preset words, kept so Restart can rebuild the same scoped set rather than
    // falling back to the home screen's own pickers.
    @State private var presetWordsSnapshot: [SavedWord] = []
    @FocusState private var isFocused: Bool

    @State private var sessionCorrect: Int = 0
    @State private var sessionWrong: Int = 0

    // Note / JLPT / scope / direction / count, persisted under this activity's own key prefix.
    @StateObject private var options = LearnActivityOptions(activity: .fillInBlank)
    private let activity = LearnActivity.fillInBlank

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
                    if isPresetSession {
                        Button {
                            if sessionActive { endSession() }
                            dismiss()
                        } label: {
                            Label(sessionActive ? "End" : "Close", systemImage: sessionActive ? "xmark.circle" : "xmark")
                        }
                    } else if sessionActive {
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
        .onAppear {
            if let presetWords, didAutoStartPreset == false {
                didAutoStartPreset = true
                isPresetSession = true
                presetWordsSnapshot = presetWords
                if let presetQuestionCount { options.count = presetQuestionCount }
                startSession(with: presetWords)
            }
        }
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

                // Escape hatch: Check is disabled on an empty field, so without this a blanked
                // question the user can't answer would strand the whole session.
                Button { reveal(question: question) } label: {
                    Label("Show Answer", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { isFocused = true }
    }

    // Correct/incorrect result plus a Next/Finish button, replacing the text field once checked. A
    // revealed answer shows the answer neutrally rather than as an incorrect attempt, even though
    // it's scored the same.
    @ViewBuilder
    private func feedback(for verdict: AnswerScorer.Verdict, correct: String) -> some View {
        VStack(spacing: 12) {
            Label(
                didReveal ? correct : (verdict.isCorrect ? "Correct" : "Incorrect — \(correct)"),
                systemImage: didReveal ? "eye" : (verdict.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
            )
            .foregroundStyle(didReveal ? Color.secondary : (verdict.isCorrect ? .green : .red))
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
        let result = AnswerScorer.grade(input: typedAnswer, anyOf: question.accepted)
        verdict = result
        isFocused = false
        if result.isCorrect {
            sessionCorrect += 1
            reviewStore.recordCorrect(
                for: question.id, direction: question.direction, hasKanjiForm: question.hasKanjiForm
            )
        } else {
            sessionWrong += 1
            reviewStore.recordAgain(
                for: question.id, direction: question.direction, hasKanjiForm: question.hasKanjiForm
            )
        }
    }

    // Gives up on the current question: shows the answer and scores it as wrong, so a word the user
    // couldn't produce still comes back around in review rather than being silently passed over.
    private func reveal(question: FillInBlankQuestion) {
        didReveal = true
        verdict = AnswerScorer.grade(input: "", anyOf: question.accepted)
        isFocused = false
        sessionWrong += 1
        reviewStore.recordAgain(
            for: question.id, direction: question.direction, hasKanjiForm: question.hasKanjiForm
        )
    }

    // Clears the answer field and verdict, and advances to the next question (or the summary).
    private func advance() {
        typedAnswer = ""
        verdict = nil
        didReveal = false
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

            Button {
                if isPresetSession {
                    startSession(with: presetWordsSnapshot)
                } else {
                    startSessionFromHome()
                }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button {
                if isPresetSession { dismiss() } else { endSession() }
            } label: {
                Label(isPresetSession ? "Done" : "Choose Different Cards",
                      systemImage: isPresetSession ? "checkmark.circle" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The shared start screen; Fill in the Blank adds no controls of its own.
    private var reviewHome: some View {
        LearnActivityHome(
            activity: activity,
            options: options,
            dictionaryStore: dictionaryStore,
            poolCount: eligibleWords().count,
            onStart: { startSessionFromHome() },
            extraSections: { EmptyView() }
        )
    }

    // Words passing every filter and askable in at least one selected direction.
    private func eligibleWords() -> [SavedWord] {
        LearnWordPool.eligibleWords(
            in: wordsStore.words, options: options,
            reviewStore: reviewStore, dictionaryStore: dictionaryStore
        )
    }

    // Resolves the question pool asynchronously, then activates the session.
    private func startSessionFromHome() {
        startSession(with: eligibleWords())
    }

    // Builds and activates a session over an explicit word set — shared by the home picker and by
    // the Coverage screen's scoped launch.
    private func startSession(with words: [SavedWord]) {
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        typedAnswer = ""
        verdict = nil
        didReveal = false
        questions = []
        let selection = options.directions
        let limit = options.count
        Task {
            let items = await LearnWordPool.resolveItems(for: words, dictionaryStore: dictionaryStore)
            let built = buildQuestions(from: items, selection: selection)
            // A positive limit caps the quiz; 0 (or blank field) means quiz everything.
            questions = limit > 0 ? Array(built.prefix(limit)) : built
            isResolving = false
        }
    }

    // Builds one question per item, in whichever of the ticked directions that word is eligible
    // for. Items where the prompt and answer would read identically (no distinct dictionary form to
    // ask about) are skipped, mirroring MultipleChoiceView's equivalent guard. The list is shuffled.
    private func buildQuestions(from items: [StudyItem], selection: DirectionSelection) -> [FillInBlankQuestion] {
        var result: [FillInBlankQuestion] = []
        for item in items {
            guard let direction = selection.resolved(seed: item.id, hasKanjiForm: item.hasKanjiForm) else { continue }
            let fields = direction.fields
            let prompt = item.value(for: fields.prompt)
            let correct = item.value(for: fields.answer)
            guard prompt != correct, correct.isEmpty == false else { continue }
            result.append(FillInBlankQuestion(
                id: item.id,
                prompt: prompt,
                correct: correct,
                direction: direction,
                // An English answer passes on any of the word's glosses; a Japanese answer has
                // exactly one accepted string.
                accepted: direction.answerIsMeaning ? item.glosses : [correct],
                hasKanjiForm: item.hasKanjiForm
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
        didReveal = false
        sessionCorrect = 0
        sessionWrong = 0
    }
}
