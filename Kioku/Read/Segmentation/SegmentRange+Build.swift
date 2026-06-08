import Foundation

extension SegmentRange {
    // Builds order-only segment ranges from segmentation edges, attaching any furigana annotations
    // whose absolute UTF-16 range falls within each segment (rebased to surface-relative offsets).
    // Shared single source of truth for the Read view's runtime rebuild (ReadView.buildSegmentRanges)
    // and the subtitle importer's precompute, so the two can't drift on how furigana maps onto
    // segments. Pure: no view or actor state, safe to call from a background import task.
    nonisolated static func ranges(
        from edges: [LatticeEdge],
        in sourceText: String,
        furiganaByLocation: [Int: String] = [:],
        furiganaLengthByLocation: [Int: Int] = [:]
    ) -> [SegmentRange] {
        edges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: sourceText)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }

            // Collect furigana whose absolute range falls within this segment, rebased to
            // surface-relative offsets.
            let segStart = nsRange.location
            let segEnd = nsRange.location + nsRange.length
            let annotations: [FuriganaAnnotation] = furiganaByLocation.compactMap { location, reading in
                guard let length = furiganaLengthByLocation[location],
                      location >= segStart, location + length <= segEnd else { return nil }
                let relativeStart = location - segStart
                return FuriganaAnnotation(start: relativeStart, end: relativeStart + length, reading: reading)
            }.sorted { $0.start < $1.start }

            return SegmentRange(surface: edge.surface, furigana: annotations.isEmpty ? nil : annotations)
        }
    }
}
