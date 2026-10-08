import Foundation

// Fills in the stretches a text edit left unsegmented (SegmentRange.needsSegmentation) from a
// segmentation of the whole text, so newly typed words get their full context, while untouched
// segments keep their boundaries, readings and word picks.
extension ReadView {
    // Splices `computedEdges` (the segmenter's pass over all of `sourceText`) into `persisted`
    // wherever the edit left a stub. An untouched segment stays as it is unless a computed word
    // joins it to edited text (戦, then a newly typed う → 戦う): its text didn't change but its word
    // did, so it takes the computed segmentation too, and so does anything that word in turn
    // reaches. nil when `persisted` or `computedEdges` don't tile `sourceText`.
    func segmentsAfterEdit(_ persisted: [SegmentRange], computedEdges: [LatticeEdge], in sourceText: String) -> [SegmentRange]? {
        var spans: [Range<Int>] = []
        var offset = 0
        for segment in persisted {
            let length = segment.surface.utf16.count
            spans.append(offset..<(offset + length))
            offset += length
        }
        guard offset == sourceText.utf16.count else { return nil }

        let words: [(range: Range<Int>, surface: String)] = computedEdges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: sourceText)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            return (nsRange.location..<(nsRange.location + nsRange.length), edge.surface)
        }
        guard words.map(\.surface).joined() == sourceText else { return nil }

        // Grow the edited set until no computed word straddles an edited and an untouched segment.
        // Both lists are in text order, so each pass is one sweep; each pass that changes anything
        // marks at least one more segment, which bounds the passes by the segment count.
        var isEdited = persisted.map { $0.needsSegmentation == true }
        var didGrow = true
        while didGrow {
            didGrow = false
            var first = 0
            for word in words {
                while first < spans.count, spans[first].upperBound <= word.range.lowerBound { first += 1 }
                var last = first
                while last < spans.count, spans[last].lowerBound < word.range.upperBound { last += 1 }
                guard first < last, isEdited[first..<last].contains(true) else { continue }
                for index in first..<last where isEdited[index] == false {
                    isEdited[index] = true
                    didGrow = true
                }
            }
        }

        // Untouched segments as they are; each edited stretch from the computed words starting in it
        // (after the growth above, every word touching an edited segment lies inside edited ones).
        var result: [SegmentRange] = []
        var nextWord = 0
        for (index, span) in spans.enumerated() {
            while nextWord < words.count, words[nextWord].range.lowerBound < span.lowerBound { nextWord += 1 }
            guard isEdited[index] else {
                result.append(persisted[index])
                continue
            }
            while nextWord < words.count, words[nextWord].range.lowerBound < span.upperBound {
                result.append(SegmentRange(surface: words[nextWord].surface))
                nextWord += 1
            }
        }
        guard result.map(\.surface).joined() == sourceText else { return nil }
        return result
    }
}
