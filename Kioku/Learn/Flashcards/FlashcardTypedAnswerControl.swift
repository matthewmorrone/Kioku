import SwiftUI

// Typed-input control shown in place of the Again/Know buttons when a Flashcards session has typed
// grading enabled and the current card's resolved direction is a production direction (English
// prompt, Japanese answer). Fetches the word's own kanji/kana independently of FlashcardCard's
// private fetch — the same per-view fetch duplication FlashcardCard/MultipleChoiceView already use
// (see FlashcardCard.resolveLiveContent's comment) rather than threading state through a new shared
// cache. Grades the typed answer via AnswerScorer and reports the outcome upward so FlashcardsView
// can record it via ReviewStore and advance the session, mirroring onKnow/onAgain.
struct FlashcardTypedAnswerControl: View {
    let word: SavedWord
    let dictionaryStore: DictionaryStore?
    let japaneseForm: StudyJapaneseForm
    let onGraded: (_ correct: Bool, _ direction: QuestionDirection?) -> Void

    @State private var typedAnswer: String = ""
    @State private var expected: ExpectedAnswer?
    @State private var verdict: AnswerScorer.Verdict?
    @FocusState private var isFocused: Bool

    private struct ExpectedAnswer {
        let text: String
        let isKanaOnlySurface: Bool
    }

    var body: some View {
        VStack(spacing: 10) {
            if let verdict {
                feedback(for: verdict)
            } else {
                TextField("Type the answer", text: $typedAnswer)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { check() }
                    .disabled(expected == nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button { check() } label: {
                    Label("Check", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(expected == nil || typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // Keyed on the word's id (not just .task's default identity) so a fresh fetch — and a reset
        // text field/verdict — happens every time the session advances to a new card, even though
        // this view instance may be reused across cards by SwiftUI's diffing.
        .task(id: word.canonicalEntryID) {
            typedAnswer = ""
            verdict = nil
            expected = await resolveExpected()
            isFocused = true
        }
    }

    // Correct/incorrect result plus a Next button, replacing the text field once the answer's checked.
    @ViewBuilder
    private func feedback(for verdict: AnswerScorer.Verdict) -> some View {
        VStack(spacing: 8) {
            Label(
                verdict.isCorrect ? "Correct" : "Incorrect — \(expected?.text ?? verdict.normalizedExpected)",
                systemImage: verdict.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(verdict.isCorrect ? .green : .red)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Button {
                onGraded(verdict.isCorrect, direction)
            } label: {
                Label("Next", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // The direction this card's grade counts as evidence for, derived the same way
    // MultipleChoiceView/FlashcardsView resolve every other englishToJapanese card — via the live
    // kana-only fact this view already fetched, which is more accurate than a surface-only guess.
    private var direction: QuestionDirection? {
        guard let expected else { return nil }
        return .forJapaneseEnglishAxis(
            resolved: .englishToJapanese, form: japaneseForm, isKanaOnlySurface: expected.isKanaOnlySurface
        )
    }

    // Grades the typed answer against the resolved expected text and shows the verdict.
    private func check() {
        guard let expected else { return }
        verdict = AnswerScorer.grade(input: typedAnswer, expected: expected.text)
        isFocused = false
    }

    // Resolves the expected Japanese text for the session's configured form, via the shared
    // WordFormResolver every quiz/study view now uses for this same kanji/kana lookup.
    private func resolveExpected() async -> ExpectedAnswer? {
        guard let store = dictionaryStore else { return nil }
        let entryID = word.canonicalEntryID
        let surface = word.surface
        let selectedSenseIDs = word.selectedSenseIDs
        let selectedGlosses = word.selectedGlosses
        let form = japaneseForm
        return await Task.detached(priority: .utility) { () -> ExpectedAnswer? in
            guard let resolved = WordFormResolver.fetchKanjiAndKana(
                store: store, entryID: entryID, surface: surface,
                selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
            ) else {
                return nil
            }
            let isKanaOnlySurface = resolved.kanji == nil
            let text: String
            switch form {
            case .kanji: text = resolved.kanji ?? surface
            case .kana: text = resolved.kana ?? surface
            case .original: text = isKanaOnlySurface ? (resolved.kana ?? surface) : (resolved.kanji ?? surface)
            }
            return ExpectedAnswer(text: text, isKanaOnlySurface: isKanaOnlySurface)
        }.value
    }
}
