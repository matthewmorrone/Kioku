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
    // configured rule to independently clear all 6 `QuestionDirection` cases — a word graduates
    // only once every direction (kanji→meaning, meaning→kana, ...) has its own evidence clearing
    // the bar, not just an aggregate whole-word streak that could come from one direction alone.
    // A direction with no recorded answers yet has zero counters, which never clears any rule.
    static func shouldMarkLearned(
        directionStats: [String: DirectionStats],
        config: LearnedSettings.Config = LearnedSettings.current()
    ) -> Bool {
        guard config.enabled else { return false }
        return QuestionDirection.allCases.allSatisfy { direction in
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
