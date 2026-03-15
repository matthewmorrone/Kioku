import SwiftUI
import UIKit

extension ReadView {
    // Splits one segment at a UTF-16 boundary selected from the segment list screen.
    func splitSegmentFromSegmentList(at edgeIndex: Int, offsetUTF16: Int) {
        guard segmentationEdges.indices.contains(edgeIndex) else {
            return
        }

        let edge = segmentationEdges[edgeIndex]
        let sourceSurface = edge.surface
        let mergedRange = NSRange(edge.start..<edge.end, in: text)
        guard offsetUTF16 > 0, offsetUTF16 < mergedRange.length else {
            return
        }

        let leftRange = NSRange(location: mergedRange.location, length: offsetUTF16)
        let rightRange = NSRange(location: mergedRange.location + offsetUTF16, length: mergedRange.length - offsetUTF16)

        guard
            let leftStringRange = Range(leftRange, in: text),
            let rightStringRange = Range(rightRange, in: text)
        else {
            return
        }

        let leftSurface = String(text[leftStringRange])
        let rightSurface = String(text[rightStringRange])
        guard leftSurface.isEmpty == false, rightSurface.isEmpty == false else {
            return
        }

        var updatedEdges = segmentationEdges

        // Applies split globally to all matching segments when enabled.
        if shouldApplyChangesGlobally {
            var newEdges: [LatticeEdge] = []

            for edge in updatedEdges {
                if edge.surface == sourceSurface {
                    let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
                    let edgeLeftRange = NSRange(location: edgeNSRange.location, length: offsetUTF16)
                    let edgeRightRange = NSRange(location: edgeNSRange.location + offsetUTF16, length: edgeNSRange.length - offsetUTF16)

                    if let edgeLeftStringRange = Range(edgeLeftRange, in: text),
                       let edgeRightStringRange = Range(edgeRightRange, in: text) {
                        let edgeLeftSurface = String(text[edgeLeftStringRange])
                        let edgeRightSurface = String(text[edgeRightStringRange])

                        if !edgeLeftSurface.isEmpty && !edgeRightSurface.isEmpty {
                            let leftEdge = LatticeEdge(
                                start: edgeLeftStringRange.lowerBound,
                                end: edgeLeftStringRange.upperBound,
                                surface: edgeLeftSurface,
                                lemma: edgeLeftSurface
                            )
                            let rightEdge = LatticeEdge(
                                start: edgeRightStringRange.lowerBound,
                                end: edgeRightStringRange.upperBound,
                                surface: edgeRightSurface,
                                lemma: edgeRightSurface
                            )
                            newEdges.append(leftEdge)
                            newEdges.append(rightEdge)
                            continue
                        }
                    }
                }
                newEdges.append(edge)
            }

            updatedEdges = newEdges
        } else {
            let leftEdge = LatticeEdge(
                start: leftStringRange.lowerBound,
                end: leftStringRange.upperBound,
                surface: leftSurface,
                lemma: leftSurface
            )
            let rightEdge = LatticeEdge(
                start: rightStringRange.lowerBound,
                end: rightStringRange.upperBound,
                surface: rightSurface,
                lemma: rightSurface
            )
            updatedEdges.replaceSubrange(edgeIndex...edgeIndex, with: [leftEdge, rightEdge])
        }

        applySegmentationEdges(updatedEdges, persistOverride: true)

        if !shouldApplyChangesGlobally {
            selectedMergedEdgeBounds = edgeIndex...edgeIndex
            selectedSegmentLocation = leftRange.location
            selectedHighlightRangeOverride = leftRange
        }
        SegmentDefinitionPopoverPresenter.shared.dismissPopover()
    }
}
