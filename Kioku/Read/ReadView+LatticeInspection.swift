import SwiftUI

// Hosts runtime lattice inspection helpers for the read screen.
extension ReadView {
    // Prints the retained lattice section for the current selected segment so the selected span's edges are visible in logs.
    func debugPrintLatticeSectionForCurrentSelection(at selectedLocation: Int) {
        guard let selectedBounds = selectedMergedEdgeBounds ?? initialMergedEdgeBounds(for: selectedLocation) else {
            return
        }

        let selectedStart = segmentationEdges[selectedBounds.lowerBound].start
        let selectedEnd = segmentationEdges[selectedBounds.upperBound].end
        let selectedSurface = String(text[selectedStart..<selectedEnd])
        let selectedRange = NSRange(selectedStart..<selectedEnd, in: text)
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return
        }

        let sectionEdges = segmentationLatticeEdges
            .filter { edge in
                edge.start >= selectedStart && edge.end <= selectedEnd
            }
            .sorted { lhs, rhs in
                let lhsRange = NSRange(lhs.start..<lhs.end, in: text)
                let rhsRange = NSRange(rhs.start..<rhs.end, in: text)

                if lhsRange.location != rhsRange.location {
                    return lhsRange.location < rhsRange.location
                }

                if lhsRange.length != rhsRange.length {
                    return lhsRange.length > rhsRange.length
                }

                if lhs.surface != rhs.surface {
                    return lhs.surface < rhs.surface
                }

                return lhs.lemma < rhs.lemma
            }

        print("LATTICE SECTION \(selectedRange.location)->\(selectedRange.location + selectedRange.length) \(selectedSurface)")
        if sectionEdges.isEmpty {
            print("  (no retained lattice edges inside selection)")
            return
        }

        for edge in sectionEdges {
            let edgeRange = NSRange(edge.start..<edge.end, in: text)
            guard edgeRange.location != NSNotFound, edgeRange.length > 0 else {
                continue
            }

            let resolutionSummary = segmenter.debugResolutionSummary(for: edge.surface, lemma: edge.lemma)
            print("  \(edgeRange.location)->\(edgeRange.location + edgeRange.length) \(edge.surface) [lemma: \(edge.lemma)] [\(resolutionSummary)]")
        }
    }
}