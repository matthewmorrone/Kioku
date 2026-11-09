import Foundation

// Decides whether a word's freshly-updated review stats earn an automatic promotion. The bar is
// one correct answer in each direction the user requires (Settings → Learning): by default Learned
// needs each recognition direction (`QuestionDirection.tier1`), Mastered every direction.
// Consulted from WordsStore.recordCorrect on every correct answer. `nonisolated` (like
// `LearnedSettings`) since it's pure rule evaluation with no MainActor state — callable from any
// context, including plain (non-`@MainActor`) unit tests.
nonisolated enum AutoLearnPolicy {
    // Learned: every direction the user requires for Learned (default: the three recognition
    // directions) has been answered right at least once.
    static func shouldMarkLearned(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        required: DirectionSelection = LearnedSettings.learnedDirections(),
        enabled: Bool = LearnedSettings.isAutoLearnEnabled()
    ) -> Bool {
        allDirectionsAnsweredCorrectly(required, hasKanjiForm: hasKanjiForm, directionStats: directionStats, enabled: enabled)
    }

    // Mastered: every direction the user requires for Mastered (default: all six) has been
    // answered right at least once.
    static func shouldMarkMastered(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        required: DirectionSelection = LearnedSettings.masteredDirections(),
        enabled: Bool = LearnedSettings.isAutoLearnEnabled()
    ) -> Bool {
        allDirectionsAnsweredCorrectly(required, hasKanjiForm: hasKanjiForm, directionStats: directionStats, enabled: enabled)
    }

    // Shared gate behind both promotion checks. False when auto-learn is off or nothing is
    // required (an empty bar never promotes). Directions a kana-only word can't be asked are
    // dropped from the bar; if that leaves nothing, one correct answer in any direction is enough,
    // so such a word is never stranded.
    private static func allDirectionsAnsweredCorrectly(
        _ required: DirectionSelection,
        hasKanjiForm: Bool,
        directionStats: [String: DirectionStats],
        enabled: Bool
    ) -> Bool {
        guard enabled, required.isEmpty == false else { return false }
        let askable = required.askable(hasKanjiForm: hasKanjiForm)
        if askable.isEmpty {
            return directionStats.values.contains { $0.correct > 0 }
        }
        return askable.allSatisfy { (directionStats[$0.rawValue]?.correct ?? 0) > 0 }
    }
}
