import Foundation
// @preconcurrency: TranslationSession.Configuration isn't yet Sendable.
@preconcurrency import Translation

// The one Japanese → user-language translation setup, shared by lyric lines and phrase-history
// rows so both translate into the same language.
nonisolated enum JapaneseTranslation {
    // Source ja; target the user's first preferred non-Japanese language, else US English.
    static var configuration: TranslationSession.Configuration {
        let target = Locale.preferredLanguages
            .first(where: { !$0.hasPrefix("ja") })
            .map { Locale.Language(identifier: $0) }
            ?? Locale.Language(identifier: "en-US")
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: target
        )
    }
}
