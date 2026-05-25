import SwiftUI
// @preconcurrency: see comment in LyricsActiveCueOverlay.swift — TranslationSession isn't
// yet Sendable but is meant to be passed into async helpers exactly like this.
@preconcurrency import Translation

// Translation pipeline for the lyrics popup — derives the TranslationSession.Configuration
// from the user's preferred locales (skipping ja so we always translate INTO a non-Japanese
// language) and batch-translates every cue up front so the user sees translations the moment
// each line becomes active. Split out of LyricsView.swift so the main file focuses on layout.
extension LyricsView {
    var translationConfig: TranslationSession.Configuration {
        let target = Locale.preferredLanguages
            .first(where: { !$0.hasPrefix("ja") })
            .map { Locale.Language(identifier: $0) }
            ?? Locale.Language(identifier: "en-US")
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: target
        )
    }

    // Batch-translates all cues that haven't been cached yet so translations are available during playback.
    // Uses the note text (via displayText) rather than cue text so translations match what's shown.
    func translateAllCues(session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            return
        }
        for index in cues.indices {
            let text = displayText(for: index)
            guard translationCache.needsTranslation(text: text) else { continue }
            do {
                let response = try await session.translate(text)
                await MainActor.run { translationCache.store(text: text, result: response.targetText) }
            } catch {
                // Individual cue failure is non-fatal — skip and continue.
            }
        }
    }
}
