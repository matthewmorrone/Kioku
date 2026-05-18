import Combine
import Foundation

// Caches on-device machine translations for subtitle cues, keyed by the cue's source text.
// Keying by text (not array index) means re-indexing the cue list — e.g., after splitting a
// multi-line cue, removing the ♪ cue, or any reorder — never serves a stale translation under
// the wrong line. Re-imports of the same lyrics also re-use existing translations.
// Translation calls happen inside .translationTask closures in the view — the session never escapes.
// Results are persisted to UserDefaults keyed by attachment ID so they survive app restarts.
@MainActor
final class LyricsTranslationCache: ObservableObject {
    @Published private(set) var translations: [String: String] = [:]

    private var attachmentID: UUID?

    // Loads persisted translations for the given attachment and populates the in-memory cache.
    func load(for attachmentID: UUID) {
        self.attachmentID = attachmentID
        let key = userDefaultsKey(for: attachmentID)
        if let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            translations = stored
        } else {
            translations = [:]
        }
    }

    // Discards all cached translations and resets the attachment identity so stale results are never shown.
    func clear() {
        attachmentID = nil
        translations = [:]
    }

    // Returns true if this cue text has no cached translation yet.
    func needsTranslation(text: String) -> Bool {
        translations[text] == nil && text.isEmpty == false
    }

    // Persists a completed translation result so repeated view appearances skip the translation API.
    func store(text: String, result: String) {
        translations[text] = result
        persist()
    }

    // Writes the current translations dict to UserDefaults.
    private func persist() {
        guard let attachmentID else { return }
        let key = userDefaultsKey(for: attachmentID)
        UserDefaults.standard.set(translations, forKey: key)
    }

    // Scopes the UserDefaults key to the attachment so different notes never share translation data.
    // The "ByText" suffix differentiates from the legacy index-keyed format so old caches don't
    // accidentally hydrate as if they were text-keyed.
    private func userDefaultsKey(for attachmentID: UUID) -> String {
        "kioku.lyricsTranslationsByText.\(attachmentID.uuidString)"
    }
}
