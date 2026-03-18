import SwiftUI
import UIKit

extension ReadView {
    // Merges one segment with its immediate neighbor from the segment list screen.
    func mergeSegmentFromSegmentList(at edgeIndex: Int, isMergingLeft: Bool) {
        guard segmentEdges.indices.contains(edgeIndex) else {
            return
        }

        let mergeBounds: ClosedRange<Int>
        let sourceLeftSurface: String
        let sourceRightSurface: String

        if isMergingLeft {
            guard edgeIndex > 0 else {
                return
            }
            let leftEdge = segmentEdges[edgeIndex - 1]
            let rightEdge = segmentEdges[edgeIndex]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return
            }
            mergeBounds = (edgeIndex - 1)...edgeIndex
            sourceLeftSurface = leftEdge.surface
            sourceRightSurface = rightEdge.surface
        } else {
            guard edgeIndex + 1 < segmentEdges.count else {
                return
            }
            let leftEdge = segmentEdges[edgeIndex]
            let rightEdge = segmentEdges[edgeIndex + 1]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return
            }
            mergeBounds = edgeIndex...(edgeIndex + 1)
            sourceLeftSurface = leftEdge.surface
            sourceRightSurface = rightEdge.surface
        }

        var updatedEdges = segmentEdges

        // Applies merge globally to all matching segment pairs when enabled.
        if shouldApplyChangesGlobally {
            var indicesToRemove: Set<Int> = []
            var newEdges: [LatticeEdge] = []

            var i = 0
            while i < updatedEdges.count {
                if i + 1 < updatedEdges.count {
                    let leftEdge = updatedEdges[i]
                    let rightEdge = updatedEdges[i + 1]

                    if leftEdge.surface == sourceLeftSurface && rightEdge.surface == sourceRightSurface && isMergeAllowed(between: leftEdge, and: rightEdge) {
                        let mergedStart = leftEdge.start
                        let mergedEnd = rightEdge.end
                        let mergedSurface = String(text[mergedStart..<mergedEnd])
                        let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface)
                        newEdges.append(mergedEdge)
                        indicesToRemove.insert(i)
                        indicesToRemove.insert(i + 1)
                        i += 2
                        continue
                    }
                }

                if !indicesToRemove.contains(i) {
                    newEdges.append(updatedEdges[i])
                }
                i += 1
            }

            updatedEdges = newEdges
        } else {
            let mergedStart = segmentEdges[mergeBounds.lowerBound].start
            let mergedEnd = segmentEdges[mergeBounds.upperBound].end
            let mergedSurface = String(text[mergedStart..<mergedEnd])
            let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface)
            updatedEdges.replaceSubrange(mergeBounds, with: [mergedEdge])
        }

        applySegmentEdges(updatedEdges, persistOverride: true)

        if !shouldApplyChangesGlobally {
            let mergedIndex = mergeBounds.lowerBound
            let mergedStart = segmentEdges[mergeBounds.lowerBound].start
            let mergedEnd = segmentEdges[mergeBounds.upperBound].end
            selectedBounds = mergedIndex...mergedIndex
            let mergedNSRange = NSRange(mergedStart..<mergedEnd, in: text)
            selectedSegmentLocation = mergedNSRange.location
            selectedHighlightRangeOverride = mergedNSRange
        }
        SegmentLookupSheet.shared.dismissPopover()
    }
}
