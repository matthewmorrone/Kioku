import Foundation

// Applies the corrections a song's Breakdown suggests (SongLineFix) to the open note, each through the
// edit it stands for: a reading pinned like Edit Reading, word breaks moved like the segment list's
// merge and split, a typo written into the text like Cleanup. The Breakdown sheet calls it with the
// note range of the fix's line. With changes applying globally (the toolbar setting) a typo or a
// reading is fixed at every occurrence in the note, as a pinned reading is from the lookup sheet.
extension ReadView {
    // Applies `fix` inside the note text at `lineRange` (and elsewhere in the note when changes apply
    // globally); returns the note text afterwards, or nil when the fix's text isn't in that line or the
    // change isn't allowed (a merge across a forbidden boundary, a reading that doesn't fit the
    // word's kanji).
    func applyBreakdownFix(_ fix: SongLineFix, inLine lineRange: NSRange) -> String? {
        let text = document.text as NSString
        guard lineRange.location != NSNotFound, NSMaxRange(lineRange) <= text.length else { return nil }
        let found = text.range(of: fix.originalSurface, range: lineRange)
        guard found.location != NSNotFound else { return nil }
        switch fix.kind {
        case .typo:
            replaceNoteText(occurrenceRanges(of: fix.originalSurface, including: found).map {
                TextConversion(
                    range: $0,
                    original: fix.originalSurface,
                    replacement: fix.replacementSurface,
                    source: .breakdown
                )
            })
        case .reading:
            // The line's occurrence, and every other segment spelled the same way when changes apply globally.
            var locations = [found.location]
            if shouldApplyChangesGlobally {
                for edge in document.segmentEdges where edge.surface == fix.originalSurface {
                    let edgeRange = NSRange(edge.start..<edge.end, in: document.text)
                    if edgeRange.location != NSNotFound, edgeRange.location != found.location { locations.append(edgeRange.location) }
                }
            }
            guard applyPerRunFurigana(surface: fix.originalSurface, reading: fix.replacementReading, at: found.location) else {
                return nil
            }
            for location in locations.dropFirst() {
                applyPerRunFurigana(surface: fix.originalSurface, reading: fix.replacementReading, at: location)
            }
            pickWord(for: fix.originalSurface, reading: fix.replacementReading, at: locations)
            // A pinned reading is a user edit, the same as one picked on the lookup sheet.
            document.hasManualSegmentationEdits = true
            rebuildAndPersistSegments()
            // A dictionary reading also goes into the word's History row, as with the sheet's arrows;
            // one the dictionary doesn't list belongs to this place in the text only.
            recordLookupHistory(
                surface: fix.originalSurface,
                reading: isDictionaryReading(fix.replacementReading, of: fix.originalSurface) ? fix.replacementReading : nil
            )
        case .split:
            guard resegment(found, into: fix.replacementWords.map { $0.utf16.count }) else { return nil }
        }
        return document.text
    }

    // When the surface is several words (the lookup sheet's possibilities list) and the corrected
    // reading names one of them, chooses that word at each location, as tapping its row does, instead
    // of leaving the pick to context. A reading shared by several of them takes the word context
    // prefers there; nothing is pinned when even that is undecided.
    private func pickWord(for surface: String, reading: String, at locations: [Int]) {
        guard let lexicon else { return }
        let candidates = lexicon.lookupCandidates(surface: surface)
        guard candidates.count > 1,
              Lexicon.lookupCandidates(candidates, sharingReading: reading).isEmpty == false else { return }
        let sharing = Lexicon.lookupCandidates(candidates, sharingReading: reading)
        for location in locations {
            let picked = sharing.count == 1
                ? sharing[0].entry.entryId
                : chosenEntryID(at: location, surface: surface, among: candidates, displayedReading: reading)
            if let picked { document.chosenEntryIDBySegmentLocation[location] = picked }
        }
    }

    // True when `reading` is one the dictionary lists for `surface` (one of the lookup sheet's arrow stops).
    private func isDictionaryReading(_ reading: String, of surface: String) -> Bool {
        guard let lexicon else { return false }
        let listed = ReadingVariants.orderedReadings(
            surface: surface,
            lexicon: lexicon,
            segmenter: segmenter,
            surfaceReadingData: surfaceReadingData
        )
        return listed.contains(reading)
            || lexicon.lookupCandidates(surface: surface).contains { $0.surfaceReadings.contains(reading) }
    }

    // Where a typo fix lands: `found` alone, or, when changes apply globally, every non-overlapping
    // occurrence of the typo's text in the note.
    private func occurrenceRanges(of surface: String, including found: NSRange) -> [NSRange] {
        guard shouldApplyChangesGlobally, surface.isEmpty == false else { return [found] }
        let text = document.text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < text.length {
            let next = text.range(of: surface, range: NSRange(location: searchStart, length: text.length - searchStart))
            guard next.location != NSNotFound else { break }
            ranges.append(next)
            searchStart = NSMaxRange(next)
        }
        return ranges.contains(found) ? ranges : [found]
    }

    // Moves the word breaks inside `range` so its words have `lengths` (UTF-16, summing to the range's
    // length): splits wherever a wanted break falls inside a segment, then merges across every break
    // that isn't wanted. Each step re-reads the edges, so the apply-globally setting's matching edits
    // elsewhere can't throw the indices off. False when the edges aren't ready or a merge is refused.
    private func resegment(_ range: NSRange, into lengths: [Int]) -> Bool {
        guard lengths.reduce(0, +) == range.length, document.segmentEdges.isEmpty == false else { return false }
        var wanted: Set<Int> = [range.location, NSMaxRange(range)]
        var cursor = range.location
        for length in lengths.dropLast() {
            cursor += length
            wanted.insert(cursor)
        }
        for boundary in wanted.sorted() {
            guard let (index, edgeRange) = edge(containing: boundary), edgeRange.location < boundary else { continue }
            guard splitEdge(at: index, offsetUTF16: boundary - edgeRange.location, updateSelection: false) != nil else {
                return false
            }
        }
        // Each merge removes one break, so the edge count bounds the loop.
        var remainingMerges = document.segmentEdges.count
        var index = firstUnwantedBreak(in: range, wanted: wanted)
        while let mergeIndex = index, remainingMerges > 0 {
            remainingMerges -= 1
            guard mergeEdges(at: mergeIndex, isMergingLeft: false, updateSelection: false) != nil else { return false }
            index = firstUnwantedBreak(in: range, wanted: wanted)
        }
        return index == nil
    }

    // The segment edge covering UTF-16 offset `location`, with its note range.
    private func edge(containing location: Int) -> (index: Int, range: NSRange)? {
        for (index, edge) in document.segmentEdges.enumerated() {
            let edgeRange = NSRange(edge.start..<edge.end, in: document.text)
            if NSLocationInRange(location, edgeRange) { return (index, edgeRange) }
        }
        return nil
    }

    // The index of the first edge inside `range` whose end is a break `wanted` doesn't name, i.e. the
    // left edge of the next pair to merge; nil when every break inside the range is wanted.
    private func firstUnwantedBreak(in range: NSRange, wanted: Set<Int>) -> Int? {
        let edges = document.segmentEdges
        for index in edges.indices.dropLast() {
            let boundary = NSMaxRange(NSRange(edges[index].start..<edges[index].end, in: document.text))
            if boundary > range.location, boundary < NSMaxRange(range), wanted.contains(boundary) == false {
                return index
            }
        }
        return nil
    }
}
