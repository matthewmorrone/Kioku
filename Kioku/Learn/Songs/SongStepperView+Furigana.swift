import Foundation
import SwiftUI

// Furigana resolution for SongStepperView's cards: per-line reading caches for the big
// Japanese row (cut from the Read tab's analysis of the note). Split out of SongStepperView so
// the view file stays focused on state and layout; everything here is called from the view's
// row-refresh path.
extension SongStepperView {

    // Eagerly resolves furigana for every displayed line, so readings are available as soon as
    // a row renders — including bare note lines and lines that are still streaming. Idempotent per (index, text): a cache whose
    // `sourceText` matches is reused; one whose text differs (a note line's index later
    // taken by a streamed line with other text) is rebuilt.
    func ensureFuriganaCaches(for lines: [SongLine]) {
        for line in lines where furiganaCacheByLineIndex[line.index]?.sourceText != line.original {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line)
        }
    }

    // A line's segments and readings, taken from the Read tab's own analysis of the note
    // (noteReadings) — the page's segmentation including the user's splits and merges, and its
    // readings including pinned corrections — so a line shows exactly what the page shows.
    // Only a line whose text sits verbatim in the note (see SongBreakdownLineLocator) can be cut
    // out that way; any other line, or a sheet opened before the Read tab finished analysing the
    // note, gets a fresh resolve of the line on its own with the Read tab's resolver.
    func buildFuriganaCache(for line: SongLine) -> LineFuriganaCache {
        if let noteReadings, noteReadings.isUsable(for: note.content),
           let range = lineNoteRangesByIndex[line.index],
           let sliced = noteReadings.slice(range),
           sliced.sourceText == line.original {
            return sliced
        }
        let text = line.original
        guard let segmenter, text.isEmpty == false else {
            return LineFuriganaCache(
                sourceText: text,
                segmentationRanges: [],
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:]
            )
        }
        let edges = segmenter.longestMatchEdges(for: text)
        let resolved = FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: text,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        return LineFuriganaCache(
            sourceText: text,
            segmentationRanges: edges.map { $0.start..<$0.end },
            furiganaBySegmentLocation: resolved.byLocation,
            furiganaLengthBySegmentLocation: resolved.lengthByLocation
        )
    }
}
