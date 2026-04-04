import Combine
import Foundation
import Translation

// Caches on-device machine translations for subtitle cues, keyed by cue index.
// Translations are requested lazily as each cue becomes active and never retried on failure.
// Must be cleared when the active note changes.
@MainActor
final class LyricsTranslationCache: ObservableObject {
    @Published private(set) var translations: [Int: String] = [:]

    private var session: TranslationSession?
    private var inFlight: Set<Int> = []

    // Clears all cached translations and the active session when switching notes.
    func clear() {
        translations = [:]
        inFlight = []
        session = nil
    }

    // Requests a translation for the given cue text and cue index.
    // Silently drops failures and duplicate in-flight requests.
    func requestTranslation(cueIndex: Int, text: String, session: TranslationSession) {
        guard translations[cueIndex] == nil, inFlight.contains(cueIndex) == false, text.isEmpty == false else {
            return
        }
        self.session = session
        inFlight.insert(cueIndex)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await session.translate(text)
                self.translations[cueIndex] = response.targetText
            } catch {
                // Translation failures are intentionally silent.
            }
            self.inFlight.remove(cueIndex)
        }
    }
}
