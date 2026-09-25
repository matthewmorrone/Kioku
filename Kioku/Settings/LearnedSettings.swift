import Foundation

// UserDefaults keys + defaults for the auto-learn feature. Bound by @AppStorage in SettingsView
// and read back by AutoLearnPolicy. Centralized here so the keys can't drift between the writer
// (Settings UI) and the reader (WordsStore.recordCorrect). `nonisolated` since the reads are plain
// synchronous UserDefaults lookups with no MainActor state — callable from any context, including
// plain (non-`@MainActor`) unit tests and AutoLearnPolicy's own nonisolated default arg.
nonisolated enum LearnedSettings {
    static let enabledKey = "kioku.autoLearn.enabled"
    // Whether the Learn tab's study modes skip words already at the Learned/Mastered stage.
    // Read by every Learn mode through StudyWordPool; written by the Settings toggle. Defaults to
    // ON — a word marked learned is one the user has said they're done drilling, so keeping it in
    // the rotation is the surprising behavior, not the other way round. Lives here rather than in
    // an @AppStorage default so the key and its default can't drift between reader and writer (the
    // Bool default has to be spelled at both, and `false` is the wrong one).
    static let excludeLearnedKey = "kioku.study.excludeLearned"

    static let defaultExcludeLearned = true

    // Reads the auto-learn switch from the shared store @AppStorage writes to.
    static func isAutoLearnEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }
}
