import Foundation

// Decides whether a word's freshly-updated review stats earn an automatic promotion. The bar is
// one correct answer in every kind of question that can be asked about the word: Learned needs
// each recognition direction (`QuestionDirection.tier1`), Mastered needs every direction.
// Consulted from WordsStore.recordCorrect on every correct answer. `nonisolated` (like
// `LearnedSettings`) since it's pure rule evaluation with no MainActor state — callable from any
// context, including plain (non-`@MainActor`) unit tests.
nonisolated enum AutoLearnPolicy {
    // Learned: every applicable recognition direction (kanji→meaning, kana→meaning, kanji→kana)
    // has been answered right at least once. `hasKanjiForm: false` drops the kanji directions (see
    // `QuestionDirection.applicable`), leaving かな→English as the whole recognition bar — without
    // it a kana-only word could never be promoted, since its kanji directions are never asked.
    static func shouldMarkLearned(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        enabled: Bool = LearnedSettings.isAutoLearnEnabled()
    ) -> Bool {
        allDirectionsAnsweredCorrectly(
            QuestionDirection.applicable(QuestionDirection.tier1, hasKanjiForm: hasKanjiForm),
            directionStats: directionStats, enabled: enabled
        )
    }

    // Mastered: the stricter sibling of `shouldMarkLearned` — every applicable direction,
    // recognition AND production, has been answered right at least once.
    static func shouldMarkMastered(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        enabled: Bool = LearnedSettings.isAutoLearnEnabled()
    ) -> Bool {
        allDirectionsAnsweredCorrectly(
            QuestionDirection.applicable(QuestionDirection.allCases, hasKanjiForm: hasKanjiForm),
            directionStats: directionStats, enabled: enabled
        )
    }

    // Shared gate behind both promotion checks: false when auto-learn is off, otherwise true only
    // when each of `directions` has at least one recorded correct answer. `directions` is the only
    // thing that varies between Learned (tier1) and Mastered (allCases).
    private static func allDirectionsAnsweredCorrectly(
        _ directions: [QuestionDirection],
        directionStats: [String: DirectionStats],
        enabled: Bool
    ) -> Bool {
        guard enabled else { return false }
        return directions.allSatisfy { (directionStats[$0.rawValue]?.correct ?? 0) > 0 }
    }
}
