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
    // The direction this card is being asked in; its answer field decides which script the typed
    // answer is compared against.
    let direction: QuestionDirection
    // `hasKanjiForm` is authoritative here (this view fetched the headword), unlike the host's
    // surface-only heuristic — see FlashcardsView.surfaceKanjiEvidence.
    let onGraded: (_ correct: Bool, _ direction: QuestionDirection?, _ hasKanjiForm: Bool?) -> Void

    @State private var typedAnswer: String = ""
    @State private var expected: ExpectedAnswer?
    @State private var verdict: AnswerScorer.Verdict?
    // Set when the user revealed the answer instead of typing one — graded as wrong (a revealed
    // answer isn't recall), but labeled neutrally rather than as a failed attempt.
    @State private var didReveal: Bool = false
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

                // Typed mode replaces Again/Know, so without this a card the user can't answer has
                // no way forward at all — Check stays disabled on an empty field.
                Button { reveal() } label: {
                    Label("Show Answer", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(expected == nil)
            }
        }
        // Keyed on the word's id (not just .task's default identity) so a fresh fetch — and a reset
        // text field/verdict — happens every time the session advances to a new card, even though
        // this view instance may be reused across cards by SwiftUI's diffing.
        .task(id: word.canonicalEntryID) {
            typedAnswer = ""
            verdict = nil
            didReveal = false
            expected = await resolveExpected()
            isFocused = true
        }
    }

    // Correct/incorrect result plus a Next button, replacing the text field once the answer's
    // checked. A revealed answer is shown neutrally rather than as an incorrect attempt.
    @ViewBuilder
    private func feedback(for verdict: AnswerScorer.Verdict) -> some View {
        let answer = expected?.text ?? verdict.normalizedExpected
        VStack(spacing: 8) {
            Label(
                didReveal ? answer : (verdict.isCorrect ? "Correct" : "Incorrect — \(answer)"),
                systemImage: didReveal ? "eye" : (verdict.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
            )
            .foregroundStyle(didReveal ? Color.secondary : (verdict.isCorrect ? .green : .red))
            .font(.headline)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Button {
                onGraded(verdict.isCorrect, direction, expected.map { $0.isKanaOnlySurface == false })
            } label: {
                Label("Next", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Gives up on the current card: shows the answer and scores it as wrong, so the word stays in
    // rotation instead of being silently passed over.
    private func reveal() {
        guard let expected else { return }
        didReveal = true
        verdict = AnswerScorer.grade(input: "", expected: expected.text)
        isFocused = false
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
        let answerField = direction.fields.answer
        return await Task.detached(priority: .utility) { () -> ExpectedAnswer? in
            guard let resolved = WordFormResolver.fetchKanjiAndKana(
                store: store, entryID: entryID, surface: surface,
                selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses
            ) else {
                return nil
            }
            let isKanaOnlySurface = resolved.kanji == nil
            // Only Japanese-script answers reach this control (see
            // FlashcardsView.isTypedGradingCard), so `.meaning` never applies; it falls back to the
            // surface rather than widening the switch.
            let text: String
            switch answerField {
            case .kanji: text = resolved.kanji ?? surface
            case .kana: text = resolved.kana ?? surface
            case .meaning: text = surface
            }
            return ExpectedAnswer(text: text, isKanaOnlySurface: isKanaOnlySurface)
        }.value
    }
}
