import SwiftUI

// Prefers a note's LLM-generated song breakdown (SongLine.gist) over Apple's on-device
// Translation framework for the lyrics popup's per-line English text, when a breakdown is
// available for the current note. The breakdown gist is usually a better contextual
// translation than a line-by-line machine translation, since the LLM sees the whole song.
// A cue is joined to its breakdown line by position in the note, falling back to its text.
// Falls back to translationCache (LyricsView+Translations.swift) for any cue the breakdown
// doesn't cover — no breakdown yet, or a cue that matches no breakdown line either way.
extension LyricsView {

    // Each breakdown line's effective gist (falling through to a referenced line's gist for
    // repeated/chorus lines, matching SongLineCard.effectiveGist), keyed two ways: by the line's
    // range in the note (SongBreakdownLineLocator — the same placement the breakdown uses for
    // its readings) and by normalized line text, for cues the alignment didn't place in the note.
    // Recomputed per access rather than cached — breakdown line counts are small (one song),
    // matching the same non-memoized-computed-property pattern SongLineCard already uses.
    private var breakdownGists: (byNoteRange: [(range: NSRange, gist: String)], byNormalizedText: [String: String]) {
        guard let noteID, let breakdown = songBreakdownStore.breakdown(forNoteID: noteID) else {
            return ([], [:])
        }
        let byIndex = Dictionary(breakdown.lines.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        // Resolves a line's own gist, or — for a `.sameAsLine`/`.parallelTo` repeat whose own
        // gist is empty — the referenced line's gist. Mirrors SongLineCard.effectiveGist.
        func effectiveGist(_ line: SongLine) -> String? {
            if let g = line.gist, g.isEmpty == false { return g }
            switch line.reference {
            case .sameAsLine(let target), .parallelTo(let target, _):
                return byIndex[target].flatMap { $0.gist }
            case nil:
                return nil
            }
        }

        let noteRanges = SongBreakdownLineLocator.noteRanges(for: breakdown.lines, in: noteText)
        var byNoteRange: [(range: NSRange, gist: String)] = []
        var byText: [String: String] = [:]
        for line in breakdown.lines {
            guard let gist = effectiveGist(line) else { continue }
            if let range = noteRanges[line.index] { byNoteRange.append((range, gist)) }
            let key = SongLineCueMatcher.normalize(line.original)
            if key.isEmpty == false, byText[key] == nil { byText[key] = gist }
        }
        return (byNoteRange, byText)
    }

    // The English text to show beneath the active cue: the gist of the breakdown line at the
    // cue's place in the note, else of a line with the cue's text, else the on-device
    // translation cache, else nil (hides the row). Music-only cues (♪) get none, so a ♪ line
    // is never followed by a second ♪. Called from the cue-rendering loop in LyricsView.swift.
    func displayedTranslation(for cueIndex: Int) -> String? {
        let text = displayText(for: cueIndex)
        guard text.isEmpty == false, SubtitleParser.isNonSpeechCue(text) == false else { return nil }
        let gists = breakdownGists
        if cueIndex < highlightRanges.count, let cueRange = highlightRanges[cueIndex],
           let match = gists.byNoteRange.first(where: { NSLocationInRange(cueRange.location, $0.range) }) {
            return match.gist
        }
        if let gist = gists.byNormalizedText[SongLineCueMatcher.normalize(text)] {
            return gist
        }
        return translationCache.translations[text]
    }
}
