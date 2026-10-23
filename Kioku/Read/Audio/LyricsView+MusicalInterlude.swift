import SwiftUI

// Non-speech (♪) cue display on the lyrics card: the interlude's notes (InterludeNotes, shared with
// the full-screen word view) in the active card, and their plain glyphs in the scrolling rows.
// Persisted cue text itself is untouched (still a plain "♪" — SubtitleParser.isNonSpeechCue keeps
// working on it); this is a display-time expansion.
extension LyricsView {
    // Whether the cue at `index` is a non-speech (♪) marker rather than a sung line.
    func isNonSpeechCue(at index: Int) -> Bool {
        guard index >= 0, index < cues.count else { return false }
        return SubtitleParser.isNonSpeechCue(cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // The active card's interlude notes, pulsing only while `isActive` (the cue is actually playing,
    // not merely scrolled into view by a drag).
    func interludeNotesRow(durationMs: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        InterludeNotes(controller: controller, durationMs: durationMs, isActive: isActive, fontSize: fontSize)
    }
}
