import Foundation
import SwiftUI

// Furigana resolution for SongStepperView's cards: per-line reading caches for the big
// Japanese row, per-headword run readings for the word list, and the overlay of readings the
// user pinned on the Read tab. Split out of SongStepperView so the view file stays focused on
// state and layout; everything here is called from the view's row-refresh path.
extension SongStepperView {

    // Eagerly resolves furigana for every displayed line and every word-list headword, so
    // readings are available as soon as a row renders — including bare note lines and
    // lines that are still streaming. Idempotent per (index, text): a cache whose
    // `sourceText` matches is reused; one whose text differs (a note line's index later
    // taken by a streamed line with other text) is rebuilt.
    func ensureFuriganaCaches(for lines: [SongLine]) {
        for line in lines where furiganaCacheByLineIndex[line.index]?.sourceText != line.original {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line)
        }
        for line in lines {
            for word in line.words {
                let key = WordFuriganaKey(lineIndex: line.index, surface: word.surface)
                guard wordFuriganaByKey[key] == nil else { continue }
                wordFuriganaByKey[key] = buildWordFuriganaRunReadings(for: word, contextLine: line)
            }
        }
    }

    // Resolves per-kanji-run readings for a single word-list headword. Prefers slicing the
    // already-resolved *line* cache (the word's readings as chosen with full sentence
    // context — okurigana, verb-phrase segmentation, etc.) when the word's surface appears
    // verbatim in that line; only isolated words (surface not found in the line, e.g. an
    // LLM-normalized headword) fall back to segmenting the surface on its own, which can
    // pick a different reading than the same characters would get in context.
    private func buildWordFuriganaRunReadings(for word: SongWord, contextLine: SongLine) -> [Int: String] {
        if let lineCache = furiganaCacheByLineIndex[contextLine.index],
           let wordRange = contextLine.original.range(of: word.surface) {
            let wordNSRange = NSRange(wordRange, in: contextLine.original)
            let sliced = lineCache.furiganaBySegmentLocation.compactMap { location, reading -> (Int, String)? in
                guard location >= wordNSRange.location,
                      location < wordNSRange.location + wordNSRange.length else { return nil }
                return (location - wordNSRange.location, reading)
            }
            if sliced.isEmpty == false {
                return Dictionary(uniqueKeysWithValues: sliced)
            }
        }
        return buildWordFuriganaRunReadings(for: word.surface)
    }

    // Resolves per-kanji-run readings for a word's surface in isolation, with no surrounding
    // sentence to segment against. Used as a fallback when the surface can't be located
    // within its source line (e.g. an LLM-normalized headword that doesn't appear verbatim).
    private func buildWordFuriganaRunReadings(for surface: String) -> [Int: String] {
        guard let segmenter, surface.isEmpty == false else { return [:] }
        let edges = segmenter.longestMatchEdges(for: surface)
        return FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: surface,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        ).byLocation
    }

    // Reuses the Read tab's resolver so the breakdown gets the exact same reading
    // selection (okurigana cropping, lemma fallback, projection) as ReadView. When the
    // segmenter is unavailable the cache resolves to "no readings" and furigana becomes
    // a visual no-op — which matches the "degrade gracefully on pure-kana lines" criterion.
    //
    // The resolver's output is a fresh recompute — it doesn't know about readings the user
    // pinned or corrected on the Read tab (Note.segments). applyNoteFuriganaOverrides overlays
    // those on top so the breakdown always shows the same reading as the underlying page.
    func buildFuriganaCache(for line: SongLine) -> LineFuriganaCache {
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
        let segmentationRanges = edges.map { $0.start..<$0.end }
        let resolved = FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: text,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        var byLocation = resolved.byLocation
        var lengthByLocation = resolved.lengthByLocation
        applyNoteFuriganaOverrides(to: &byLocation, lengthByLocation: &lengthByLocation, forLineIndex: line.index)
        return LineFuriganaCache(
            sourceText: text,
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: byLocation,
            furiganaLengthBySegmentLocation: lengthByLocation
        )
    }

    // Overlays any reading the user pinned or corrected on the Read tab (persisted in
    // `note.segments`, restored into `noteFuriganaRestoration`) onto this line's freshly
    // resolved furigana. Only swaps the reading text at a location the fresh segmentation
    // already produced a same-length entry for — a location/length mismatch (e.g. the user
    // manually merged or split segments on the Read tab, shifting boundaries) just falls back
    // to the freshly-resolved default rather than trying to reconcile differing boundaries.
    // Regenerating the breakdown always picks up the correct reading regardless.
    private func applyNoteFuriganaOverrides(
        to byLocation: inout [Int: String],
        lengthByLocation: inout [Int: Int],
        forLineIndex lineIndex: Int
    ) {
        guard let restoration = noteFuriganaRestoration,
              let lineStart = lineStartOffsetsByIndex[lineIndex] else { return }
        for (location, length) in lengthByLocation {
            let globalLocation = lineStart + location
            guard restoration.lengthByLocation[globalLocation] == length,
                  let reading = restoration.byLocation[globalLocation] else { continue }
            byLocation[location] = reading
        }
    }

    // Restores the note's persisted per-note reading overrides (Note.segments), keyed by
    // UTF-16 offset within note.content. Nil when the note has no persisted segments or they
    // no longer validate against its current content (e.g. edited outside the segment-aware
    // editor) — callers degrade to the freshly-resolved default in that case.
    static func restoreNoteFurigana(from note: Note) -> (byLocation: [Int: String], lengthByLocation: [Int: Int])? {
        guard let normalized = SegmentRangeRestoration.normalizedSegmentRanges(note.segments, for: note.content) else { return nil }
        return SegmentRangeRestoration.furiganaFromSegmentRanges(normalized)
    }

    // Finds each displayed line's starting UTF-16 offset within note.content, so a note-level
    // reading override can be rebased into that line's local coordinates. Searches in line
    // order, advancing the cursor past each match, so a repeated chorus line resolves to its
    // own occurrence rather than always the first. A line whose text isn't found verbatim
    // (e.g. the LLM normalized it slightly) is simply omitted — its furigana falls back to the
    // freshly-resolved default.
    static func lineStartOffsets(for lines: [SongLine], in noteContent: String) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var searchStart = noteContent.startIndex
        for line in lines where line.original.isEmpty == false {
            guard let range = noteContent.range(of: line.original, range: searchStart..<noteContent.endIndex) else { continue }
            offsets[line.index] = NSRange(range, in: noteContent).location
            searchStart = range.upperBound
        }
        return offsets
    }
}
