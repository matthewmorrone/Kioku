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

        let sectionEdges = Lattice.sectionEdges(
            from: segmentationLatticeEdges,
            in: text,
            selectedStart: selectedStart,
            selectedEnd: selectedEnd
        )

        let debugLines = Lattice.debugSectionLines(
            sectionEdges: sectionEdges,
            in: text,
            sectionRange: selectedRange,
            sectionSurface: selectedSurface,
            resolutionSummary: { surface, lemma in
                segmenter.debugResolutionSummary(for: surface, lemma: lemma)
            }
        )

        for line in debugLines {
            print(line)
        }
    }
}