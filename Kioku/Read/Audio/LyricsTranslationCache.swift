import Combine
import Foundation

// Caches on-device machine translations for subtitle cues, keyed by cue index.
// Translation calls happen inside .translationTask closures in the view — the session never escapes.
// Results are persisted to UserDefaults keyed by attachment ID so they survive app restarts.
// Must be cleared (and a new attachmentID set) on note/attachment change.
@MainActor
final class LyricsTranslationCache: ObservableObject {
    @Published private(set) var translations: [Int: String] = [:]

    private var attachmentID: UUID?

    // Loads persisted translations for the given attachment and populates the in-memory cache.
    func load(for attachmentID: UUID) {
        self.attachmentID = attachmentID
        let key = userDefaultsKey(for: attachmentID)
        if let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            translations = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in
                guard let index = Int(k) else { return nil }
                return (index, v)
            })
        } else {
            translations = [:]
        }
    }

    func clear() {
        attachmentID = nil
        translations = [:]
    }

    // Returns true if this cue needs translation (not yet cached, non-empty text).
    func needsTranslation(cueIndex: Int, text: String) -> Bool {
        translations[cueIndex] == nil && text.isEmpty == false
    }

    func store(cueIndex: Int, result: String) {
        translations[cueIndex] = result
        persist()
    }

    // Writes the current translations dict to UserDefaults.
    private func persist() {
        guard let attachmentID else { return }
        let key = userDefaultsKey(for: attachmentID)
        let stringKeyed = Dictionary(uniqueKeysWithValues: translations.map { ("\($0.key)", $0.value) })
        UserDefaults.standard.set(stringKeyed, forKey: key)
    }

    private func userDefaultsKey(for attachmentID: UUID) -> String {
        "kioku.lyricsTranslations.\(attachmentID.uuidString)"
    }
}
