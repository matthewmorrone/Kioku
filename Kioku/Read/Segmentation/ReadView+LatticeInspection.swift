import SwiftUI

// Hosts runtime lattice inspection helpers for the read screen.
extension ReadView {
    // Prints the retained lattice section for the current selected segment so the selected span's edges are visible in logs.
    func inspectLattice(at selectedLocation: Int) {
        guard let selectedBounds = selectedBounds ?? initialMergedEdgeBounds(for: selectedLocation),
              selectedBounds.lowerBound < segmentEdges.count,
              selectedBounds.upperBound < segmentEdges.count else {
            return
        }

        let selectedStart = segmentEdges[selectedBounds.lowerBound].start
        let selectedEnd = segmentEdges[selectedBounds.upperBound].end
        let selectedRange = NSRange(selectedStart..<selectedEnd, in: text)
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return
        }

        let sectionEdges = Lattice.sectionEdges(
            from: segmentLatticeEdges,
            in: text,
            selectedStart: selectedStart,
            selectedEnd: selectedEnd
        )

        let lines = sectionEdges.map { edge in
            let startOffset = text.distance(from: text.startIndex, to: edge.start)
            let endOffset = text.distance(from: text.startIndex, to: edge.end)
            return "  [\(startOffset),\(endOffset)) \(edge.surface)"
        }
        AppLog.debug(.segmentation, "inspectLattice: \(sectionEdges.count) edge(s) in selected span:\n\(lines.joined(separator: "\n"))")
    }
}
