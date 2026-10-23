import SwiftUI

// Prefers a note's LLM-generated song breakdown (SongLine.gist) over Apple's on-device
// Translation framework for the lyrics popup's per-line English text, when a breakdown is
// available for the current note. The breakdown gist is usually a better contextual
// translation than a line-by-line machine translation, since the LLM sees the whole song.
// A cue is joined to its breakdown line through SongBreakdownPlacement: by position in the
// note, falling back to its text. Falls back to translationCache (LyricsView+Translations.swift)
// for any cue the breakdown doesn't cover — no breakdown yet, or a cue that matches no
// breakdown line either way.
extension LyricsView {

    // The note's breakdown placed on its text, nil without a breakdown. Shared with the word
    // bubbles (LyricsView+WordBubbles).
    var breakdownPlacement: SongBreakdownPlacement? {
        noteID.flatMap { songBreakdownStore.placement(forNoteID: $0, noteText: noteText) }
    }

    // The English text to show beneath the active cue: the gist of the breakdown line at the
    // cue's place in the note, else of a line with the cue's text, else the on-device
    // translation cache, else nil (hides the row). Music-only cues (♪) get none, so a ♪ line
    // is never followed by a second ♪. Called from the cue-rendering loop in LyricsView.swift.
    func displayedTranslation(for cueIndex: Int) -> String? {
        let text = displayText(for: cueIndex)
        guard text.isEmpty == false, SubtitleParser.isNonSpeechCue(text) == false else { return nil }
        let cueLocation = cueIndex < highlightRanges.count ? highlightRanges[cueIndex]?.location : nil
        if let gist = breakdownPlacement?.gist(atNoteLocation: cueLocation, text: text) {
            return gist
        }
        return translationCache.translations[text]
    }
}
