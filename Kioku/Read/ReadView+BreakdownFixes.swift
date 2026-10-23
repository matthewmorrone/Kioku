import Foundation

// Applies the corrections a song's Breakdown suggests (SongLineFix) to the open note, each through the
// edit it stands for: a reading pinned like Edit Reading, word breaks moved like the segment list's
// merge and split, a typo written into the text like Cleanup. The Breakdown sheet calls it with the
// note range of the fix's line.
extension ReadView {
    // Applies `fix` inside the note text at `lineRange`; returns the note text afterwards, or nil when
    // the fix's text isn't in that line or the change isn't allowed (a merge across a forbidden
    // boundary, a reading that doesn't fit the word's kanji).
    func applyBreakdownFix(_ fix: SongLineFix, inLine lineRange: NSRange) -> String? {
        let text = document.text as NSString
        guard lineRange.location != NSNotFound, NSMaxRange(lineRange) <= text.length else { return nil }
        let found = text.range(of: fix.originalSurface, range: lineRange)
        guard found.location != NSNotFound else { return nil }
        switch fix.kind {
        case .typo:
            replaceNoteText([TextConversion(
                range: found,
                original: fix.originalSurface,
                replacement: fix.replacementSurface,
                source: .breakdown
            )])
        case .reading:
            guard applyPerRunFurigana(surface: fix.originalSurface, reading: fix.replacementReading, at: found.location) else {
                return nil
            }
            // A pinned reading is a user edit, the same as one picked on the lookup sheet.
            document.hasManualSegmentationEdits = true
            rebuildAndPersistSegments()
        case .split:
            guard resegment(found, into: fix.replacementWords.map { $0.utf16.count }) else { return nil }
        }
        return document.text
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
