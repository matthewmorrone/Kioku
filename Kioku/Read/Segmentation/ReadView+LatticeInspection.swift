import SwiftUI

// Hosts runtime lattice inspection helpers for the read screen.
extension ReadView {
    // Prints the retained lattice section for the current selected segment so the selected span's edges are visible in logs.
    func inspectLattice(at selectedLocation: Int) {
        guard let selectedBounds = segmentSelection.selectedBounds ?? initialMergedEdgeBounds(for: selectedLocation),
              selectedBounds.lowerBound < document.segmentEdges.count,
              selectedBounds.upperBound < document.segmentEdges.count else {
            return
        }

        let selectedStart = document.segmentEdges[selectedBounds.lowerBound].start
        let selectedEnd = document.segmentEdges[selectedBounds.upperBound].end
        let selectedRange = NSRange(selectedStart..<selectedEnd, in: document.text)
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return
        }

        let sectionEdges = Lattice.sectionEdges(
            from: document.segmentLatticeEdges,
            in: document.text,
            selectedStart: selectedStart,
            selectedEnd: selectedEnd
        )

        let lines = sectionEdges.map { edge in
            let startOffset = document.text.distance(from: document.text.startIndex, to: edge.start)
            let endOffset = document.text.distance(from: document.text.startIndex, to: edge.end)
            return "  [\(startOffset),\(endOffset)) \(edge.surface)"
        }
        AppLog.debug(.segmentation, "inspectLattice: \(sectionEdges.count) edge(s) in selected span:\n\(lines.joined(separator: "\n"))")
    }
}
