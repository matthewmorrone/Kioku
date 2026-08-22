import SwiftUI

// One assembled question: a prompt, the shuffled options (including the correct one), and which
// option is correct. Options are plain strings so comparison and feedback colouring are trivial.
struct MultipleChoiceQuestion: Identifiable {
    let id: Int64
    let prompt: String
    let options: [String]
    let correct: String
    // Which of the 6 directions this question exercises, so answering it feeds that direction's
    // own evidence in ReviewStore (see QuestionDirection).
    let direction: QuestionDirection
    // Carried from the source item so answering can tell ReviewStore which promotion bar applies.
    let hasKanjiForm: Bool
}

// Renders the multiple-choice study mode: home configuration, active quiz, and summary.
// Modeled on FlashcardsView (same scope/note pickers, same ReviewStore grading) but objective:
// a tap is unambiguously right or wrong, so it grades automatically instead of self-assessment.
// Major sections: toolbar, question header, prompt + option buttons, review home form, summary.
struct MultipleChoiceView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // When non-nil, opens directly into a scoped session over these words (Coverage drill-down).
    var presetWords: [SavedWord]? = nil
    // The question cap the Coverage launch sheet's count field settled on; nil means "use the
    // default".
    var presetQuestionCount: Int? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    @State private var questions: [MultipleChoiceQuestion] = []
    // Guards the preset auto-start so it fires exactly once.
    @State private var didAutoStartPreset: Bool = false
    // True for the lifetime of a Coverage-launched sheet — see FlashcardsView's isPresetSession for
    // why "End"/"Choose Different Cards"/"Restart" all need to behave differently here than they do
    // for a normal, home-screen-launched session.
    @State private var isPresetSession: Bool = false
    // The original preset words, kept around so Restart can rebuild the same scoped set — unlike
    // `startSessionFromHome()`, which always pulls from the unfiltered note/scope/level pickers.
    @State private var presetWordsSnapshot: [SavedWord] = []
    @State private var index: Int = 0
    @State private var selected: String?
    // Set when the user gave up rather than picking. Scored wrong like any miss, but it highlights
    // the answer without blaming a choice the user never made.
    @State private var didReveal: Bool = false
    @State private var sessionActive: Bool = false
    @State private var isResolving: Bool = false

    @State private var sessionCorrect: Int = 0
    @State private var sessionWrong: Int = 0

    // Note / JLPT / scope / direction / count, persisted under this activity's own key prefix.
    @StateObject private var options = LearnActivityOptions(activity: .multipleChoice)
    private let activity = LearnActivity.multipleChoice
    // Skip words already at the Learned/Mastered stage. Shared with the other Learn modes via
    // LearnedSettings; toggled in Settings → Learning. See StudyWordPool.
    @AppStorage(LearnedSettings.excludeLearnedKey) private var excludeLearned = LearnedSettings.defaultExcludeLearned

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

            // Every other activity offers a way past a question you can't answer; without this the
            // only exit here is a deliberate wrong guess, which reads as a worse answer than
            // admitting you don't know. Kept in the layout once answered — hidden rather than
            // removed — so the prompt and options don't slide down into the space it vacated.
            Button { reveal(question: question) } label: {
                Label("Show Answer", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .opacity(selected == nil ? 1 : 0)
            .allowsHitTesting(selected == nil)
            .accessibilityHidden(selected != nil)
        }
    }

    // Gives up on the current question: highlights the correct option and scores it wrong, so the
    // word stays in rotation rather than being silently passed over.
    private func reveal(question: MultipleChoiceQuestion) {
        guard selected == nil else { return }
        didReveal = true
        selected = question.correct
        sessionWrong += 1
        wordsStore.recordAgain(
            for: question.id, direction: question.direction, hasKanjiForm: question.hasKanjiForm
        )
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
                if isPresetSession {
                    dismiss()
                } else {
                    endSession()
                }
            } label: {
                Label(isPresetSession ? "Done" : "Choose Different Cards", systemImage: isPresetSession ? "checkmark.circle" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The shared start screen — identical for every activity.
    private var reviewHome: some View {
        LearnActivityHome(
            activity: activity,
            options: options,
            dictionaryStore: dictionaryStore,
            pool: pool(),
            onStart: { startSessionFromHome() }
        )
    }

    // Words passing every filter and askable in at least one selected direction, plus the count
    // the learned exclusion held back.
    private func pool() -> StudyWordSelection {
        LearnWordPool.eligible(
            in: wordsStore.words, options: options, excludeLearned: excludeLearned,
            wordsStore: wordsStore, dictionaryStore: dictionaryStore
        )
    }

    // Resolves the question pool asynchronously, then activates the session.
    private func startSessionFromHome() {
        startSession(with: pool().words)
    }

    // Builds and activates a session over an explicit word set — shared by the home picker and by
    // the Coverage screen's scoped launch.
    private func startSession(with words: [SavedWord]) {
        sessionActive = true
        isResolving = true
        sessionCorrect = 0
        sessionWrong = 0
        index = 0
        selected = nil
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

    // Records the answer against ReviewStore (correct feeds SRS, wrong marks for relearn) and
    // freezes the option buttons so the feedback colours stay until the user taps Next.
    private func answer(_ option: String, correct: String) {
        guard selected == nil, didReveal == false else { return }
        selected = option
        let id = questions[index].id
        let direction = questions[index].direction
        let hasKanjiForm = questions[index].hasKanjiForm
        if option == correct {
            sessionCorrect += 1
            wordsStore.recordCorrect(for: id, direction: direction, hasKanjiForm: hasKanjiForm)
        } else {
            sessionWrong += 1
            wordsStore.recordAgain(for: id, direction: direction, hasKanjiForm: hasKanjiForm)
        }
    }

    // Advances to the next question, or falls through to the summary when the pool is exhausted.
    private func advance() {
        selected = nil
        didReveal = false
        index += 1
    }

    // Clears all session state, returning to the home screen.
    private func endSession() {
        sessionActive = false
        isResolving = false
        questions = []
        index = 0
        selected = nil
        didReveal = false
        sessionCorrect = 0
        sessionWrong = 0
    }

    // Builds one question per item, drawing up to three distinct distractors from the other
    // items' answer-side strings. Items the selection can't ask at all, whose prompt and answer
    // would read identically, or whose answer side has no distinct distractors are dropped. The
    // final question list is shuffled.
    private func buildQuestions(from items: [StudyItem], selection: DirectionSelection) -> [MultipleChoiceQuestion] {
        // Per-field answer pools so distractor selection stays O(1) per question. Each candidate
        // carries its owner's word class, which is what lets the selector keep an option set from
        // being three nouns and the verb that must therefore be the answer.
        let fieldPools: [StudyField: [DistractorCandidate]] = [
            .kanji: candidates(from: items, field: .kanji),
            .kana: candidates(from: items, field: .kana),
            .meaning: candidates(from: items, field: .meaning),
        ]

        var result: [MultipleChoiceQuestion] = []
        for item in items {
            // One direction per word, picked from the ticked set it's eligible for and stable per
            // entry id so the question doesn't reshape between re-renders.
            guard let direction = selection.resolved(seed: item.id, hasKanjiForm: item.hasKanjiForm) else { continue }
            let fields = direction.fields
            let prompt = item.value(for: fields.prompt)
            let correct = item.value(for: fields.answer)
            // A word whose kanji and kana both fall back to the same surface has no real
            // distinction between the two sides — skip rather than ask it.
            guard prompt != correct else { continue }

            // Every other item whose own prompt-side value also equals this question's prompt is
            // "correct-equivalent" (e.g. やみ and くらやみ both meaning "darkness") — its answer-side
            // value must be excluded from the distractor pool, not just the literal `correct`
            // string, or a synonym gets offered as a "wrong" option.
            let collidingAnswers = Set(
                items.filter { $0.value(for: fields.prompt) == prompt }.map { $0.value(for: fields.answer) }
            )
            var distractorPool = (fieldPools[fields.answer] ?? [])
                .filter { collidingAnswers.contains($0.text) == false && $0.text != correct }
            guard distractorPool.isEmpty == false else { continue }

            // Shuffled first so the selector's ties break randomly; it then reorders by how well
            // each candidate imitates the answer's word class and okurigana.
            distractorPool.shuffle()
            let distractors = DistractorSelector.choose(
                from: distractorPool,
                answer: DistractorCandidate(text: correct, wordClass: item.wordClass),
                prompt: prompt,
                count: optionCount - 1
            )

            var options = distractors + [correct]
            options.shuffle()
            result.append(MultipleChoiceQuestion(
                id: item.id,
                prompt: prompt,
                options: options,
                correct: correct,
                direction: direction,
                hasKanjiForm: item.hasKanjiForm
            ))
        }
        result.shuffle()
        return result
    }

    // The distinct answer-side strings available for one field, each tagged with the word class of
    // the item it came from. Deduplicated by text: two items sharing a spelling would otherwise let
    // the same string be offered twice in one question.
    private func candidates(from items: [StudyItem], field: StudyField) -> [DistractorCandidate] {
        var seen: Set<String> = []
        var result: [DistractorCandidate] = []
        for item in items {
            let text = item.value(for: field)
            guard seen.insert(text).inserted else { continue }
            result.append(DistractorCandidate(text: text, wordClass: item.wordClass))
        }
        return result
    }
}
