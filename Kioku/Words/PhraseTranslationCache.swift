import Combine
import Foundation

// On-device translations of the Japanese phrases in Words history, keyed by the phrase text, so
// each phrase is translated once. Persisted to UserDefaults so they survive restarts; pruned to
// the phrases history still holds whenever it is translated against (history is bounded).
@MainActor
final class PhraseTranslationCache: ObservableObject {
    @Published private(set) var translations: [String: String]

    private static let defaultsKey = "kioku.phraseTranslations"

    // Loads the persisted translations.
    init() {
        translations = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    // The phrases among `phrases` with no translation yet.
    func untranslated(_ phrases: [String]) -> [String] {
        phrases.filter { translations[$0] == nil }
    }

    // Records one result and persists.
    func store(phrase: String, translation: String) {
        translations[phrase] = translation
        UserDefaults.standard.set(translations, forKey: Self.defaultsKey)
    }

    // Drops translations of phrases history no longer holds, so the cache stays history-sized.
    func prune(keeping phrases: Set<String>) {
        let kept = translations.filter { phrases.contains($0.key) }
        guard kept.count != translations.count else { return }
        translations = kept
        UserDefaults.standard.set(translations, forKey: Self.defaultsKey)
    }
}
