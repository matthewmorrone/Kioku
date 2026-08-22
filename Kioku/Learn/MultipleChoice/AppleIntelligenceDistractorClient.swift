import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Improves multiple-choice options with the on-device model (iOS 26+), which is asked to do the
// two things the heuristic selector can't: tell whether the pool's candidates are actually
// confusable with the answer rather than merely the same kind of word, and supply near-misses when
// they aren't.
//
// Everything here is best-effort. The model is small, may be unavailable, busy, or wrong, and the
// user is mid-quiz — so every failure path returns nil and leaves the heuristic option set exactly
// as it was. Nothing the model says reaches a question without passing
// `DistractorRefinementPolicy`, and invented Japanese words are checked against JMdict first.
@available(iOS 26.0, *)
enum AppleIntelligenceDistractorClient {
    #if canImport(FoundationModels)

    // The model's answer, in the shape it has to fill in. Kept to three short fields: the
    // on-device model degrades quickly as the output schema grows.
    @Generable
    struct Response {
        @Guide(description: "The 1-3 options from the supplied candidate list that a learner who half-knows the word would most plausibly confuse with the correct answer, best first. Copy them exactly as given. Never include the correct answer.")
        let chosen: [String]

        @Guide(description: "True only if the supplied candidates are all so unrelated to the correct answer that the question is too easy — a learner could pick the answer without knowing the word.")
        let poolIsTooShallow: Bool

        @Guide(description: "Only when the pool is too shallow: up to 3 additional wrong answers that are close in meaning to the correct answer but definitely NOT correct. Real, common Japanese words in the same script as the correct answer, or plain English meanings when the answer is English. Empty otherwise.")
        let invented: [String]
    }

    private static let instructions = """
    You write wrong answers for a Japanese vocabulary quiz.

    A good wrong answer is one a learner who half-knows the word would seriously consider: close in \
    meaning, in the same grammatical class, and written the same way as the correct answer. A bad \
    wrong answer is obviously unrelated — it turns the question into a giveaway.

    Never offer the correct answer, a synonym of it, or a different way of writing it. Never invent \
    Japanese words that do not exist.
    """

    // Asks the model to re-rank one question's options and, if it judges the pool too shallow, to
    // propose near-misses. Returns nil whenever the model is unavailable or its answer can't be
    // trusted; the caller keeps the heuristic options in that case.
    //
    // `isRealWord` gates every invented Japanese option on an actual dictionary hit — the model
    // will otherwise coin plausible-looking non-words, which is worse than a weak distractor
    // because the learner can't tell it isn't one.
    static func refine(
        request: DistractorRequest,
        isRealWord: @escaping (String) -> Bool
    ) async -> DistractorRefinement? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard request.candidates.isEmpty == false else { return nil }

        let session = LanguageModelSession(instructions: instructions)
        // Same low temperature the correction client settled on: this task wants the model's
        // judgement, not its imagination.
        let options = GenerationOptions(temperature: 0.1)
        do {
            let response = try await session.respond(
                to: prompt(for: request),
                generating: Response.self,
                options: options
            )
            let raw = DistractorRefinement(
                chosen: response.content.chosen,
                poolIsTooShallow: response.content.poolIsTooShallow,
                invented: response.content.invented
            )
            let picks = DistractorRefinementPolicy.acceptedPicks(raw, request: request)
            let invented = DistractorRefinementPolicy.acceptedInventions(
                raw, request: request, alreadyChosen: picks, isRealWord: isRealWord
            )
            AppLog.debug(
                .llmCorrection,
                "[AppleIntelligence] distractors for \(request.prompt): kept \(picks.count) of \(raw.chosen.count), shallow=\(raw.poolIsTooShallow), invented \(invented.count) of \(raw.invented.count)"
            )
            return DistractorRefinement(
                chosen: picks, poolIsTooShallow: raw.poolIsTooShallow, invented: invented
            )
        } catch {
            AppLog.debug(.llmCorrection, "[AppleIntelligence] distractor refinement failed: \(error)")
            return nil
        }
    }

    // The per-question request. Answer side named explicitly because "write the reading" and
    // "write the meaning" want very different wrong answers, and the strings alone don't say which
    // question this is.
    private static func prompt(for request: DistractorRequest) -> String {
        let side: String
        switch request.answerField {
        case .kanji: side = "the kanji spelling of a Japanese word"
        case .kana: side = "the kana reading of a Japanese word"
        case .meaning: side = "the English meaning of a Japanese word"
        }
        return """
        Question prompt: \(request.prompt)
        Correct answer (\(side)): \(request.correct)
        Candidate wrong answers: \(request.candidates.joined(separator: ", "))

        Pick the most confusable candidates. Judge whether these candidates make a fair question.
        """
    }

    #else

    // Stands in where Foundation Models isn't in the SDK at all: no refinement is possible, and
    // every caller already treats nil as "keep the heuristic options".
    static func refine(
        request: DistractorRequest,
        isRealWord: @escaping (String) -> Bool
    ) async -> DistractorRefinement? { nil }

    #endif
}
