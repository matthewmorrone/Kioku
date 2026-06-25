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
// (Settings UI) and the reader (ReviewStore.recordCorrect).
enum LearnedSettings {
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
// Consulted from ReviewStore.recordCorrect on every correct answer.
enum AutoLearnPolicy {
    // Gate + dispatch: returns false immediately when auto-learn is off, otherwise defers the
    // real verdict to clearsBar so the rule logic stays in one isolated place.
    static func shouldMarkLearned(
        stats: ReviewWordStats,
        config: LearnedSettings.Config = LearnedSettings.current()
    ) -> Bool {
        guard config.enabled else { return false }
        return clearsBar(stats: stats, config: config)
    }

    // Evaluates the configured rule against the word's counters. See AutoLearnRule for what
    // each case means; the comparison fields come from ReviewWordStats (accuracy/total/streak).
    private static func clearsBar(
        stats: ReviewWordStats,
        config: LearnedSettings.Config
    ) -> Bool {
        switch config.rule {
        case .accuracyOnly:
            // A single correct review already counts (total ≥ 1, accuracy 100%). The total > 0
            // guard only matters if this is ever called on an unreviewed word.
            return stats.total > 0 && (stats.accuracy ?? 0) >= config.threshold
        case .accuracyAndMinReviews:
            // Both gates: enough attempts to be meaningful AND the accuracy bar.
            return stats.total >= config.minReviews && (stats.accuracy ?? 0) >= config.threshold
        case .consecutiveCorrect:
            // A clean run since the last "again"; overall lifetime ratio is ignored.
            return stats.consecutiveCorrect >= config.streak
        }
    }
}
