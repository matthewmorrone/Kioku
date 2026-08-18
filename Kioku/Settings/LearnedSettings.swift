import Foundation

// The rule that decides when a word is automatically promoted to "learned" after a correct
// review. The user picks which one applies in Settings; each interprets the configured
// numbers differently (see AutoLearnPolicy).
enum AutoLearnRule: String, CaseIterable, Identifiable {
    // accuracy ≥ threshold AND total reviews ≥ minReviews. Guards against "one lucky correct
    // answer = 100% accuracy = learned" — the most conservative everyday choice.
    case accuracyAndMinReviews
    // accuracy ≥ threshold, regardless of how few reviews. Promotes the fastest.
    case accuracyOnly
    // consecutiveCorrect ≥ streak — a run of right answers in a row, ignoring lifetime ratio.
    case consecutiveCorrect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accuracyAndMinReviews: "Accuracy + min reviews"
        case .accuracyOnly:          "Accuracy only"
        case .consecutiveCorrect:    "Consecutive correct"
        }
    }
}

// UserDefaults keys + defaults for the auto-learn feature. Bound by @AppStorage in SettingsView
// and read back by AutoLearnPolicy. Centralized here so the keys can't drift between the writer
// (Settings UI) and the reader (ReviewStore.recordCorrect). `nonisolated` since `current()` is a
// plain synchronous UserDefaults read with no MainActor state — callable from any context,
// including plain (non-`@MainActor`) unit tests and AutoLearnPolicy's own nonisolated default arg.
nonisolated enum LearnedSettings {
    static let enabledKey    = "kioku.autoLearn.enabled"
    static let ruleKey       = "kioku.autoLearn.rule"
    static let thresholdKey  = "kioku.autoLearn.threshold"   // accuracy fraction, 0.0…1.0
    static let minReviewsKey = "kioku.autoLearn.minReviews"
    static let streakKey     = "kioku.autoLearn.streak"
    // Whether the Learn tab's study modes skip words already at the Learned/Mastered stage.
    // Read by every Learn mode through StudyWordPool; written by the Settings toggle. Defaults to
    // ON — a word marked learned is one the user has said they're done drilling, so keeping it in
    // the rotation is the surprising behavior, not the other way round. Lives here rather than in
    // an @AppStorage default so the key and its default can't drift between reader and writer (the
    // Bool default has to be spelled at both, and `false` is the wrong one).
    static let excludeLearnedKey = "kioku.study.excludeLearned"

    static let defaultExcludeLearned = true

    static let defaultThreshold  = 0.9
    static let defaultMinReviews = 3
    static let defaultStreak     = 5

    // Reads the current configuration from the shared store @AppStorage writes to.
    static func current(_ defaults: UserDefaults = .standard) -> Config {
        Config(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            rule: AutoLearnRule(rawValue: defaults.string(forKey: ruleKey) ?? "")
                ?? .accuracyAndMinReviews,
            threshold: defaults.object(forKey: thresholdKey) as? Double ?? defaultThreshold,
            minReviews: defaults.object(forKey: minReviewsKey) as? Int ?? defaultMinReviews,
            streak: defaults.object(forKey: streakKey) as? Int ?? defaultStreak
        )
    }

    // Snapshot of the five knobs, resolved with defaults for any the user hasn't touched.
    struct Config {
        var enabled: Bool
        var rule: AutoLearnRule
        var threshold: Double
        var minReviews: Int
        var streak: Int
    }
}

// Decides whether a word's freshly-updated review stats clear the auto-learn bar.
// Consulted from ReviewStore.recordCorrect on every correct answer. `nonisolated` (like
// `LearnedSettings`) since it's pure rule evaluation with no MainActor state — callable from any
// context, including plain (non-`@MainActor`) unit tests.
nonisolated enum AutoLearnPolicy {
    // Gate + dispatch: returns false immediately when auto-learn is off, otherwise requires the
    // configured rule to independently clear the 3 recognition (`QuestionDirection.tier1`) cases —
    // a word reaches Learned once every recognition direction (kanji→meaning, kana→meaning,
    // kanji→kana) has its own evidence clearing the bar, not just an aggregate whole-word streak
    // that could come from one direction alone. See `shouldMarkMastered` for the stricter, all-6-
    // direction bar. `hasKanjiForm: false` drops the kanji directions from the requirement (see
    // `QuestionDirection.applicable`), leaving かな→English as the whole recognition bar — without
    // it a kana-only word could never be promoted, since its kanji directions are never asked.
    static func shouldMarkLearned(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        config: LearnedSettings.Config = LearnedSettings.current()
    ) -> Bool {
        allDirectionsClearBar(
            QuestionDirection.applicable(QuestionDirection.tier1, hasKanjiForm: hasKanjiForm),
            directionStats: directionStats, config: config
        )
    }

    // Stricter sibling of `shouldMarkLearned`: requires every direction, recognition AND
    // production (all 6 `QuestionDirection` cases), to clear the bar — the Mastered stage.
    static func shouldMarkMastered(
        directionStats: [String: DirectionStats],
        hasKanjiForm: Bool = true,
        config: LearnedSettings.Config = LearnedSettings.current()
    ) -> Bool {
        allDirectionsClearBar(
            QuestionDirection.applicable(QuestionDirection.allCases, hasKanjiForm: hasKanjiForm),
            directionStats: directionStats, config: config
        )
    }

    // Shared gate behind both promotion checks above: false immediately when auto-learn is off,
    // otherwise true only when every one of `directions` independently clears the configured
    // rule. A direction with no recorded answers yet has zero counters, which never clears any
    // rule. `directions` is the only thing that varies between Learned (tier1) and Mastered
    // (allCases) — data-driven rather than duplicated per stage.
    private static func allDirectionsClearBar(
        _ directions: [QuestionDirection],
        directionStats: [String: DirectionStats],
        config: LearnedSettings.Config
    ) -> Bool {
        guard config.enabled else { return false }
        return directions.allSatisfy { direction in
            let ds = directionStats[direction.rawValue] ?? DirectionStats()
            return clearsBar(correct: ds.correct, again: ds.again, consecutiveCorrect: ds.consecutiveCorrect, config: config)
        }
    }

    // Evaluates the configured rule against one set of counters. See AutoLearnRule for what each
    // case means. Takes raw counters (rather than ReviewWordStats/DirectionStats directly) so the
    // same rule logic serves both the whole-word and the per-direction counters.
    static func clearsBar(
        correct: Int,
        again: Int,
        consecutiveCorrect: Int,
        config: LearnedSettings.Config
    ) -> Bool {
        let total = correct + again
        let accuracy: Double? = total > 0 ? Double(correct) / Double(total) : nil
        switch config.rule {
        case .accuracyOnly:
            // A single correct review already counts (total ≥ 1, accuracy 100%). The total > 0
            // guard only matters if this is ever called with no recorded answers.
            return total > 0 && (accuracy ?? 0) >= config.threshold
        case .accuracyAndMinReviews:
            // Both gates: enough attempts to be meaningful AND the accuracy bar.
            return total >= config.minReviews && (accuracy ?? 0) >= config.threshold
        case .consecutiveCorrect:
            // A clean run since the last "again"; overall lifetime ratio is ignored.
            return consecutiveCorrect >= config.streak
        }
    }
}
