import Foundation
import SwiftUI

// Furigana resolution for SongStepperView's cards: per-line reading caches for the big
// Japanese row (cut from the Read tab's analysis of the note) and per-headword run readings
// for the word list. Split out of SongStepperView so the view file stays focused on
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
                guard wordFuriganaCacheByKey[key] == nil else { continue }
                wordFuriganaCacheByKey[key] = buildWordFuriganaCache(for: word, contextLine: line)
            }
        }
    }

    // Resolves a word-list headword's furigana as a full LineFuriganaCache — the same shape
    // buildFuriganaCache produces for a whole line — so word headwords render through the exact
    // same KiokuCoreTextRendererView the Read tab and this card's own big Japanese row use,
    // instead of a second, separate single-word ruby renderer. Prefers slicing the already-
    // resolved *line* cache (the word's readings as chosen with full sentence context —
    // okurigana, verb-phrase segmentation, etc.) when the word's surface appears verbatim in
    // that line; only isolated words (surface not found in the line, e.g. an LLM-normalized
    // headword) fall back to segmenting the surface on its own, which can pick a different
    // reading than the same characters would get in context.
    func buildWordFuriganaCache(for word: SongWord, contextLine: SongLine) -> LineFuriganaCache {
        let surface = word.surface
        if let lineCache = furiganaCacheByLineIndex[contextLine.index],
           let wordRange = contextLine.original.range(of: surface) {
            let wordNSRange = NSRange(wordRange, in: contextLine.original)
            var byLocation: [Int: String] = [:]
            var lengthByLocation: [Int: Int] = [:]
            for (location, reading) in lineCache.furiganaBySegmentLocation {
                guard location >= wordNSRange.location,
                      location < wordNSRange.location + wordNSRange.length else { continue }
                let localLocation = location - wordNSRange.location
                byLocation[localLocation] = reading
                lengthByLocation[localLocation] = lineCache.furiganaLengthBySegmentLocation[location]
            }
            if byLocation.isEmpty == false {
                // Slice the LINE's real segment boundaries too, not one synthetic span
                // covering the whole word. KiokuCoreTextAttributedStringBuilder's ruby-overhang
                // kern compensation pushes apart SEGMENT boundaries, not run boundaries — a
                // multi-run word like 花の命 (segmented as 花 / の / 命) needs 命's own segment
                // boundary against の to get left-side kern room; collapsing everything to one
                // span makes 命 look like it's mid-segment with no boundary to push against,
                // silently disabling that compensation for every run but the very first.
                let slicedSegments: [Range<String.Index>] = lineCache.segmentationRanges.compactMap { range in
                    let nsRange = NSRange(range, in: contextLine.original)
                    guard nsRange.location >= wordNSRange.location,
                          nsRange.location + nsRange.length <= wordNSRange.location + wordNSRange.length else { return nil }
                    let lowerOffset = nsRange.location - wordNSRange.location
                    let upperOffset = lowerOffset + nsRange.length
                    return String.Index(utf16Offset: lowerOffset, in: surface)..<String.Index(utf16Offset: upperOffset, in: surface)
                }
                return LineFuriganaCache(
                    sourceText: surface,
                    segmentationRanges: slicedSegments.isEmpty ? [surface.startIndex..<surface.endIndex] : slicedSegments,
                    furiganaBySegmentLocation: byLocation,
                    furiganaLengthBySegmentLocation: lengthByLocation
                )
            }
        }
        return buildWordFuriganaCache(forIsolated: surface)
    }

    // Resolves a word's furigana in isolation, with no surrounding sentence to segment against.
    // Used as a fallback when the surface can't be located within its source line (e.g. an
    // LLM-normalized headword that doesn't appear verbatim).
    //
    // Treats `surface` as a single, already-known word — a `SongWord` bullet is one atomic
    // vocabulary item by construction — rather than asking the segmenter to rediscover word
    // boundaries inside it via `longestMatchEdges`. With no surrounding sentence to weigh frequency
    // against, the segmenter's cost model can favor splitting a real compound into its individual
    // kanji when the compound's own frequency rank is worse than its parts' (王子様 "prince" would
    // come out 王/子/様, each kanji read in isolation). A single synthetic edge spanning the whole
    // surface removes that option: FuriganaResolver.build still uses its full
    // lemma/projection/fallback pipeline (including the last-resort per-kanji reading for a surface
    // that genuinely isn't a dictionary word), it's just never given the option to sub-divide a
    // string this function already knows is one word — that's about READING resolution only.
    //
    // segmentationRanges is independent: one span per kanji run (see kanjiRunSegments) rather than
    // one span for the whole surface, so KiokuCoreTextAttributedStringBuilder's ruby-overhang kern
    // compensation — which pushes apart SEGMENT boundaries, not run boundaries — has a real
    // neighbor to push for every run but the very first, the same as buildFuriganaCache's real
    // per-line segments give it.
    private func buildWordFuriganaCache(forIsolated surface: String) -> LineFuriganaCache {
        guard let segmenter, surface.isEmpty == false else {
            return LineFuriganaCache(
                sourceText: surface,
                segmentationRanges: [],
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:]
            )
        }
        let wholeWordEdge = LatticeEdge(
            start: surface.startIndex,
            end: surface.endIndex,
            surface: surface,
            lemma: segmenter.preferredLemma(for: surface) ?? surface
        )
        let resolved = FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: surface,
            edges: [wholeWordEdge],
            surfaceReadingData: surfaceReadingData
        )
        return LineFuriganaCache(
            sourceText: surface,
            segmentationRanges: Self.kanjiRunSegments(in: surface),
            furiganaBySegmentLocation: resolved.byLocation,
            furiganaLengthBySegmentLocation: resolved.lengthByLocation
        )
    }

    // Derives kern-compensation segment boundaries for an isolated surface with no real
    // sentence segmentation available: one span per kanji run, extended through any trailing
    // kana up to the next kanji run (or the surface's end) so okurigana stays grouped with its
    // kanji — the same shape a real sentence segmenter's segments would have for a compound
    // like 儚く. Falls back to one whole-surface span when the surface has no kanji runs at all
    // (pure kana, or empty).
    private static func kanjiRunSegments(in surface: String) -> [Range<String.Index>] {
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return [surface.startIndex..<surface.endIndex] }
        let length = surface.utf16.count
        var segments: [Range<String.Index>] = []
        if let first = runs.first, first.start > 0 {
            segments.append(surface.startIndex..<String.Index(utf16Offset: first.start, in: surface))
        }
        for (i, run) in runs.enumerated() {
            let end = i + 1 < runs.count ? runs[i + 1].start : length
            segments.append(String.Index(utf16Offset: run.start, in: surface)..<String.Index(utf16Offset: end, in: surface))
        }
        return segments
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
