import SwiftUI
import UIKit

// Handles merge and split operations on the active segment selection in the read screen.
extension ReadView {
    // Resolves the initial merged edge bounds for the currently selected segment location.
    func initialMergedEdgeBounds(for selectedLocation: Int) -> ClosedRange<Int>? {
        guard let selectedIndex = segmentEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == selectedLocation && edgeNSRange.length > 0
        }) else {
            return nil
        }

        return selectedIndex...selectedIndex
    }

    // Resolves immediate left and right segment surfaces around the active merged edge bounds.
    func adjacentSegmentSurfaces(for selectedLocation: Int) -> (left: String?, right: String?) {
        let activeBounds = selectedBounds ?? initialMergedEdgeBounds(for: selectedLocation)
        guard let activeBounds else {
            return (left: nil, right: nil)
        }

        let leftSurface = activeBounds.lowerBound > 0 ? segmentEdges[activeBounds.lowerBound - 1].surface : nil
        let rightIndex = activeBounds.upperBound + 1
        let rightSurface = rightIndex < segmentEdges.count ? segmentEdges[rightIndex].surface : nil
        return (left: leftSurface, right: rightSurface)
    }

    // Applies a merge against the current merged bounds and returns updated popover payload fields.
    func mergeAdjacentSegment(isMergingLeft: Bool) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let currentBounds = selectedBounds ?? selectedSegmentLocation.flatMap({ location in
            initialMergedEdgeBounds(for: location)
        }) else {
            return nil
        }

        let nextBounds: ClosedRange<Int>
        if isMergingLeft {
            guard currentBounds.lowerBound > 0 else {
                return nil
            }
            let leftEdge = segmentEdges[currentBounds.lowerBound - 1]
            let rightEdge = segmentEdges[currentBounds.lowerBound]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            nextBounds = (currentBounds.lowerBound - 1)...currentBounds.upperBound
        } else {
            guard currentBounds.upperBound + 1 < segmentEdges.count else {
                return nil
            }
            let leftEdge = segmentEdges[currentBounds.upperBound]
            let rightEdge = segmentEdges[currentBounds.upperBound + 1]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            nextBounds = currentBounds.lowerBound...(currentBounds.upperBound + 1)
        }

        let mergedStart = segmentEdges[nextBounds.lowerBound].start
        let mergedEnd = segmentEdges[nextBounds.upperBound].end
        let mergedSurface = String(text[mergedStart..<mergedEnd])
        let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface)
        let sourceLeftSurface = segmentEdges[nextBounds.lowerBound].surface
        let sourceRightSurface = segmentEdges[nextBounds.upperBound].surface

        var updatedEdges = segmentEdges
        if shouldApplyChangesGlobally {
            var globallyMergedEdges: [LatticeEdge] = []
            var edgeIndex = 0

            while edgeIndex < updatedEdges.count {
                if edgeIndex + 1 < updatedEdges.count {
                    let leftEdge = updatedEdges[edgeIndex]
                    let rightEdge = updatedEdges[edgeIndex + 1]

                    if leftEdge.surface == sourceLeftSurface,
                       rightEdge.surface == sourceRightSurface,
                       isMergeAllowed(between: leftEdge, and: rightEdge) {
                        let globalMergedSurface = String(text[leftEdge.start..<rightEdge.end])
                        globallyMergedEdges.append(
                            LatticeEdge(
                                start: leftEdge.start,
                                end: rightEdge.end,
                                surface: globalMergedSurface
                            )
                        )
                        edgeIndex += 2
                        continue
                    }
                }

                globallyMergedEdges.append(updatedEdges[edgeIndex])
                edgeIndex += 1
            }

            updatedEdges = globallyMergedEdges
        } else {
            updatedEdges.replaceSubrange(nextBounds, with: [mergedEdge])
        }

        applySegmentEdges(updatedEdges, persistOverride: true)

        guard let mergedIndex = updatedEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == NSRange(mergedStart..<mergedEnd, in: text).location && edge.surface == mergedSurface
        }) else {
            return nil
        }

        selectedBounds = mergedIndex...mergedIndex
        let mergedNSRange = NSRange(updatedEdges[mergedIndex].start..<updatedEdges[mergedIndex].end, in: text)
        selectedSegmentLocation = mergedNSRange.location
        selectedHighlightRangeOverride = mergedNSRange

        let leftNeighborSurface = mergedIndex > 0 ? updatedEdges[mergedIndex - 1].surface : nil
        let rightNeighborIndex = mergedIndex + 1
        let rightNeighborSurface = rightNeighborIndex < updatedEdges.count ? updatedEdges[rightNeighborIndex].surface : nil
        return (surface: mergedSurface, leftNeighborSurface: leftNeighborSurface, rightNeighborSurface: rightNeighborSurface)
    }

    // Applies a split offset against the current merged selection and returns updated popover payload fields.
    func applySplitSelection(offsetUTF16: Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let mergedRange = currentMergedSelectionNSRange() else {
            return nil
        }

        guard offsetUTF16 > 0, offsetUTF16 < mergedRange.length else {
            return nil
        }

        let leftRange = NSRange(location: mergedRange.location, length: offsetUTF16)
        let rightRange = NSRange(location: mergedRange.location + offsetUTF16, length: mergedRange.length - offsetUTF16)
        guard
            let leftSurface = substring(for: leftRange),
            let rightSurface = substring(for: rightRange)
        else {
            return nil
        }

        guard let mergedEdgeIndex = segmentEdges.firstIndex(where: { edge in
            let edgeRange = NSRange(edge.start..<edge.end, in: text)
            return edgeRange.location == mergedRange.location && edgeRange.length == mergedRange.length
        }) else {
            return nil
        }

        guard
            let leftStringRange = Range(leftRange, in: text),
            let rightStringRange = Range(rightRange, in: text)
        else {
            return nil
        }

        let leftEdge = LatticeEdge(
            start: leftStringRange.lowerBound,
            end: leftStringRange.upperBound,
            surface: leftSurface
        )
        let rightEdge = LatticeEdge(
            start: rightStringRange.lowerBound,
            end: rightStringRange.upperBound,
            surface: rightSurface
        )

        var updatedEdges = segmentEdges
        let sourceSurface = String(text[leftStringRange.lowerBound..<rightStringRange.upperBound])
        if shouldApplyChangesGlobally {
            var globallySplitEdges: [LatticeEdge] = []

            for edge in updatedEdges {
                if edge.surface == sourceSurface {
                    let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
                    let edgeLeftRange = NSRange(location: edgeNSRange.location, length: offsetUTF16)
                    let edgeRightRange = NSRange(location: edgeNSRange.location + offsetUTF16, length: edgeNSRange.length - offsetUTF16)

                    if let edgeLeftStringRange = Range(edgeLeftRange, in: text),
                       let edgeRightStringRange = Range(edgeRightRange, in: text) {
                        let edgeLeftSurface = String(text[edgeLeftStringRange])
                        let edgeRightSurface = String(text[edgeRightStringRange])

                        if edgeLeftSurface.isEmpty == false, edgeRightSurface.isEmpty == false {
                            globallySplitEdges.append(
                                LatticeEdge(
                                    start: edgeLeftStringRange.lowerBound,
                                    end: edgeLeftStringRange.upperBound,
                                    surface: edgeLeftSurface
                                )
                            )
                            globallySplitEdges.append(
                                LatticeEdge(
                                    start: edgeRightStringRange.lowerBound,
                                    end: edgeRightStringRange.upperBound,
                                    surface: edgeRightSurface
                                )
                            )
                            continue
                        }
                    }
                }

                globallySplitEdges.append(edge)
            }

            updatedEdges = globallySplitEdges
        } else {
            updatedEdges.replaceSubrange(mergedEdgeIndex...mergedEdgeIndex, with: [leftEdge, rightEdge])
        }

        applySegmentEdges(updatedEdges, persistOverride: true)

        guard let selectedLeftEdgeIndex = updatedEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == leftRange.location && edge.surface == leftSurface
        }) else {
            return nil
        }

        selectedBounds = selectedLeftEdgeIndex...selectedLeftEdgeIndex
        selectedSegmentLocation = leftRange.location
        selectedHighlightRangeOverride = leftRange

        let leftNeighborSurface = selectedLeftEdgeIndex > 0 ? updatedEdges[selectedLeftEdgeIndex - 1].surface : nil
        return (surface: leftSurface, leftNeighborSurface: leftNeighborSurface, rightNeighborSurface: rightSurface)
    }

    // Resolves the currently highlighted merged segment range used by merge/split actions.
    func currentMergedSelectionNSRange() -> NSRange? {
        if let selectedHighlightRangeOverride,
           selectedHighlightRangeOverride.location != NSNotFound,
           selectedHighlightRangeOverride.length > 0 {
            return selectedHighlightRangeOverride
        }

        if let mergedBounds = selectedBounds {
            let mergedStart = segmentEdges[mergedBounds.lowerBound].start
            let mergedEnd = segmentEdges[mergedBounds.upperBound].end
            let mergedNSRange = NSRange(mergedStart..<mergedEnd, in: text)
            if mergedNSRange.location != NSNotFound, mergedNSRange.length > 0 {
                return mergedNSRange
            }
        }

        guard let selectedSegmentLocation else {
            return nil
        }

        return segmentRanges.compactMap { segmentRange in
            let nsRange = NSRange(segmentRange, in: text)
            return nsRange.location == selectedSegmentLocation && nsRange.length > 0 ? nsRange : nil
        }.first
    }

    // Extracts a substring for an NSRange in current read text.
    func substring(for nsRange: NSRange) -> String? {
        guard
            nsRange.location != NSNotFound,
            nsRange.length > 0,
            let range = Range(nsRange, in: text)
        else {
            return nil
        }

        return String(text[range])
    }
}
