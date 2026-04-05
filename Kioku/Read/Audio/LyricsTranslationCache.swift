import Combine
import Foundation

// Caches on-device machine translations for subtitle cues, keyed by cue index.
// Translation calls happen inside .translationTask closures in the view — the session never escapes.
// Only the string results are stored here. Must be cleared on note/attachment change.
@MainActor
final class LyricsTranslationCache: ObservableObject {
    @Published private(set) var translations: [Int: String] = [:]

    func clear() {
        translations = [:]
    }

    // Returns true if this cue needs translation (not yet cached, non-empty text).
    func needsTranslation(cueIndex: Int, text: String) -> Bool {
        translations[cueIndex] == nil && text.isEmpty == false
    }

    func store(cueIndex: Int, result: String) {
        translations[cueIndex] = result
    }
}
