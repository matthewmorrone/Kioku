import SwiftUI
// @preconcurrency: TranslationSession isn't yet Sendable but is passed into async helpers like this.
@preconcurrency import Translation

// Translations under the Japanese phrase rows in Words history, from Apple's on-device
// translation (the same setup as lyric lines, JapaneseTranslation).
extension WordsView {
    // The Japanese phrases history holds, for translation.
    var japanesePhraseHistory: [String] {
        historyStore.entries
            .filter { $0.kind == .query && ScriptClassifier.containsJapanese($0.surface) }
            .map(\.surface)
    }

    // Starts (or re-runs) the translation task when history has phrases without a translation.
    // Device only: on a simulator the service presents a blocking unsupported-feature sheet.
    func requestPhraseTranslations() {
        #if !targetEnvironment(simulator)
        phraseTranslations.prune(keeping: Set(japanesePhraseHistory))
        guard phraseTranslations.untranslated(japanesePhraseHistory).isEmpty == false else { return }
        if phraseTranslationTrigger == nil {
            phraseTranslationTrigger = JapaneseTranslation.configuration
        } else {
            phraseTranslationTrigger?.invalidate()
        }
        #endif
    }

    // Translates every phrase that has no translation yet, one at a time, storing each as it lands.
    func translatePhrases(session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            AppLog.error(.dictionary, "phrase translation unavailable: \(error)")
            return
        }
        for phrase in phraseTranslations.untranslated(japanesePhraseHistory) {
            do {
                let response = try await session.translate(phrase)
                phraseTranslations.store(phrase: phrase, translation: response.targetText)
            } catch {
                AppLog.error(.dictionary, "phrase translation failed (\(phrase.count) chars): \(error)")
            }
        }
    }
}
