import SwiftUI

// Prefers a note's LLM-generated song breakdown (SongLine.gist) over Apple's on-device
// Translation framework for the lyrics popup's per-line English text, when a breakdown is
// available for the current note. The breakdown gist is usually a better contextual
// translation than a line-by-line machine translation, since the LLM sees the whole song.
// Falls back to translationCache (LyricsView+Translations.swift) for any cue the breakdown
// doesn't cover — no breakdown yet, or a cue whose text didn't text-match any breakdown line.
extension LyricsView {

    // Normalized cue text → the breakdown line's effective gist (falling through to a
    // referenced line's gist for repeated/chorus lines, matching SongLineCard.effectiveGist).
    // Recomputed per access rather than cached — breakdown line counts are small (one song),
    // matching the same non-memoized-computed-property pattern SongLineCard already uses.
    private var breakdownGistByNormalizedText: [String: String] {
        guard let noteID, let breakdown = songBreakdownStore.breakdown(forNoteID: noteID) else {
            return [:]
        }
        let byIndex = Dictionary(uniqueKeysWithValues: breakdown.lines.map { ($0.index, $0) })

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

        var result: [String: String] = [:]
        for line in breakdown.lines {
            guard let gist = effectiveGist(line) else { continue }
            let key = SongLineCueMatcher.normalize(line.original)
            guard key.isEmpty == false else { continue }
            result[key] = gist
        }
        return result
    }

    // The English text to show beneath the active cue: the breakdown's gist when the note has
    // one covering this cue, otherwise the on-device translation cache, otherwise nil (hides
    // the row). Called from the cue-rendering loop in LyricsView.swift.
    func displayedTranslation(for cueIndex: Int) -> String? {
        let text = displayText(for: cueIndex)
        guard text.isEmpty == false else { return nil }
        if let gist = breakdownGistByNormalizedText[SongLineCueMatcher.normalize(text)] {
            return gist
        }
        return translationCache.translations[text]
    }
}
