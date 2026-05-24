import SwiftUI
import UIKit

// Handles merge and split operations on the active segment selection in the read screen.
// Both the bottom sheet (selection-driven) and the segment list (row-driven) go through
// the same primitives so they share one set of guards, one mutation path, and one
// selection-update policy — no per-surface duplication.
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
    // Returns nil for a side when the boundary is illegal (newline, punctuation) so that
    // merge buttons are disabled before the user can attempt the operation.
    func adjacentSegmentSurfaces(for selectedLocation: Int) -> (left: String?, right: String?) {
        let activeBounds = selectedBounds ?? initialMergedEdgeBounds(for: selectedLocation)
        guard let activeBounds else {
            return (left: nil, right: nil)
        }

        var leftSurface: String? = nil
        if activeBounds.lowerBound > 0 {
            let leftEdge = segmentEdges[activeBounds.lowerBound - 1]
            let currentEdge = segmentEdges[activeBounds.lowerBound]
            if isMergeAllowed(between: leftEdge, and: currentEdge) {
                leftSurface = leftEdge.surface
            }
        }

        var rightSurface: String? = nil
        let rightIndex = activeBounds.upperBound + 1
        if rightIndex < segmentEdges.count {
            let currentEdge = segmentEdges[activeBounds.upperBound]
            let rightEdge = segmentEdges[rightIndex]
            if isMergeAllowed(between: currentEdge, and: rightEdge) {
                rightSurface = rightEdge.surface
            }
        }

        return (left: leftSurface, right: rightSurface)
    }

    // Shared merge primitive — the single source of truth for merging two adjacent edges.
    //
    // Merges `segmentEdges[edgeIndex - 1]` with `segmentEdges[edgeIndex]` when merging left,
    // or `segmentEdges[edgeIndex]` with `segmentEdges[edgeIndex + 1]` otherwise. Returns the
    // post-merge index of the merged edge. Once the bounds and `isMergeAllowed` guards pass,
    // the model is mutated and a valid index is always returned — no silent post-mutation
    // failures. Callers that need a tuple (surface + neighbors) for UI refresh derive it
    // from the returned index against the post-mutation `segmentEdges` array.
    //
    // In global mode the same merge is applied to every adjacent pair whose surfaces match;
    // the returned index points to the merged edge produced at this call site's position.
    func mergeEdges(at edgeIndex: Int, isMergingLeft: Bool, updateSelection: Bool) -> Int? {
        guard segmentEdges.indices.contains(edgeIndex) else { return nil }

        let mergeBounds: ClosedRange<Int>
        if isMergingLeft {
            guard edgeIndex > 0 else { return nil }
            let leftEdge = segmentEdges[edgeIndex - 1]
            let rightEdge = segmentEdges[edgeIndex]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            mergeBounds = (edgeIndex - 1)...edgeIndex
        } else {
            guard edgeIndex + 1 < segmentEdges.count else { return nil }
            let leftEdge = segmentEdges[edgeIndex]
            let rightEdge = segmentEdges[edgeIndex + 1]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            mergeBounds = edgeIndex...(edgeIndex + 1)
        }

        let sourceLeftSurface = segmentEdges[mergeBounds.lowerBound].surface
        let sourceRightSurface = segmentEdges[mergeBounds.upperBound].surface
        let mergedStart = segmentEdges[mergeBounds.lowerBound].start
        let mergedEnd = segmentEdges[mergeBounds.upperBound].end
        let mergedSurface = String(text[mergedStart..<mergedEnd])
        let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface)

        var updatedEdges = segmentEdges
        var resultIndex = mergeBounds.lowerBound

        if shouldApplyChangesGlobally {
            // Apply the same merge to every adjacent pair matching the source surfaces.
            // Track the post-global-merge position of THIS call's pair so the caller can
            // re-focus selection on the right edge after global mode shifts indices.
            var globallyMergedEdges: [LatticeEdge] = []
            var i = 0
            var indexOfTargetMerge = -1
            while i < updatedEdges.count {
                if i + 1 < updatedEdges.count {
                    let leftEdge = updatedEdges[i]
                    let rightEdge = updatedEdges[i + 1]
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
                        if i == mergeBounds.lowerBound {
                            indexOfTargetMerge = globallyMergedEdges.count - 1
                        }
                        i += 2
                        continue
                    }
                }
                globallyMergedEdges.append(updatedEdges[i])
                i += 1
            }
            updatedEdges = globallyMergedEdges
            // Fallback to lowerBound if the per-position tracker missed (defensive — the
            // global loop iterates monotonically so the target position should always hit).
            resultIndex = indexOfTargetMerge >= 0 ? indexOfTargetMerge : mergeBounds.lowerBound
        } else {
            updatedEdges.replaceSubrange(mergeBounds, with: [mergedEdge])
        }

        applySegmentEdges(updatedEdges, persistOverride: true)

        if updateSelection, segmentEdges.indices.contains(resultIndex) {
            let resolvedEdge = segmentEdges[resultIndex]
            selectedBounds = resultIndex...resultIndex
            let mergedNSRange = NSRange(resolvedEdge.start..<resolvedEdge.end, in: text)
            selectedSegmentLocation = mergedNSRange.location
            selectedHighlightRangeOverride = mergedNSRange
        }

        return resultIndex
    }

    // Shared split primitive — the single source of truth for splitting an edge in two.
    //
    // Splits `segmentEdges[edgeIndex]` at `offsetUTF16` (relative to the edge's start) into
    // two adjacent edges. Returns the (leftIndex, rightIndex) pair of the new edges. Once
    // the bounds and offset guards pass, the model is mutated and valid indices are always
    // returned — no silent post-mutation failures.
    //
    // In global mode the same split is applied to every edge whose surface matches; the
    // returned indices point to the pieces produced at this call site's position.
    func splitEdge(at edgeIndex: Int, offsetUTF16: Int, updateSelection: Bool) -> (leftIndex: Int, rightIndex: Int)? {
        guard segmentEdges.indices.contains(edgeIndex) else { return nil }

        let sourceEdge = segmentEdges[edgeIndex]
        let sourceSurface = sourceEdge.surface
        let sourceNSRange = NSRange(sourceEdge.start..<sourceEdge.end, in: text)
        guard offsetUTF16 > 0, offsetUTF16 < sourceNSRange.length else { return nil }

        let leftRange = NSRange(location: sourceNSRange.location, length: offsetUTF16)
        let rightRange = NSRange(
            location: sourceNSRange.location + offsetUTF16,
            length: sourceNSRange.length - offsetUTF16
        )
        guard
            let leftStringRange = Range(leftRange, in: text),
            let rightStringRange = Range(rightRange, in: text)
        else {
            return nil
        }

        let leftSurface = String(text[leftStringRange])
        let rightSurface = String(text[rightStringRange])
        guard leftSurface.isEmpty == false, rightSurface.isEmpty == false else { return nil }

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
        var resultLeftIndex = edgeIndex
        var resultRightIndex = edgeIndex + 1

        if shouldApplyChangesGlobally {
            // Apply the same split to every edge with a matching surface. Track this call
            // site's left-piece index across the global loop so selection lands correctly.
            var globallySplitEdges: [LatticeEdge] = []
            var indexOfTargetLeft = -1
            for (sourceIdx, edge) in updatedEdges.enumerated() {
                if edge.surface == sourceSurface {
                    let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
                    let edgeLeftRange = NSRange(location: edgeNSRange.location, length: offsetUTF16)
                    let edgeRightRange = NSRange(
                        location: edgeNSRange.location + offsetUTF16,
                        length: edgeNSRange.length - offsetUTF16
                    )

                    if let edgeLeftStringRange = Range(edgeLeftRange, in: text),
                       let edgeRightStringRange = Range(edgeRightRange, in: text) {
                        let edgeLeftSurface = String(text[edgeLeftStringRange])
                        let edgeRightSurface = String(text[edgeRightStringRange])

                        if edgeLeftSurface.isEmpty == false, edgeRightSurface.isEmpty == false {
                            if sourceIdx == edgeIndex {
                                indexOfTargetLeft = globallySplitEdges.count
                            }
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
            resultLeftIndex = indexOfTargetLeft >= 0 ? indexOfTargetLeft : edgeIndex
            resultRightIndex = resultLeftIndex + 1
        } else {
            updatedEdges.replaceSubrange(edgeIndex...edgeIndex, with: [leftEdge, rightEdge])
        }

        applySegmentEdges(updatedEdges, persistOverride: true)

        if updateSelection, segmentEdges.indices.contains(resultLeftIndex) {
            let resolvedLeftEdge = segmentEdges[resultLeftIndex]
            let resolvedLeftNSRange = NSRange(resolvedLeftEdge.start..<resolvedLeftEdge.end, in: text)
            selectedBounds = resultLeftIndex...resultLeftIndex
            selectedSegmentLocation = resolvedLeftNSRange.location
            selectedHighlightRangeOverride = resolvedLeftNSRange
        }

        return (leftIndex: resultLeftIndex, rightIndex: resultRightIndex)
    }

    // Bottom-sheet merge entry point: derives the target edge from the current selection,
    // delegates to `mergeEdges`, then assembles the (surface, neighbors) tuple the sheet's
    // header refresh needs. Once `mergeEdges` returns a non-nil index, the merged edge and
    // its neighbors are read from the post-mutation `segmentEdges` — no second re-lookup
    // that could fail after the model has changed.
    func mergeAdjacentSegment(isMergingLeft: Bool) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let currentBounds = selectedBounds ?? selectedSegmentLocation.flatMap({ location in
            initialMergedEdgeBounds(for: location)
        }) else {
            return nil
        }
        // Anchor at the lower bound for left merge, upper bound for right merge so that a
        // multi-edge selection extends in the expected direction. Single-edge selections
        // (the common case) collapse to the same index either way.
        let anchorIndex = isMergingLeft ? currentBounds.lowerBound : currentBounds.upperBound

        guard let mergedIndex = mergeEdges(
            at: anchorIndex,
            isMergingLeft: isMergingLeft,
            updateSelection: true
        ) else {
            return nil
        }

        let mergedEdge = segmentEdges[mergedIndex]
        let leftNeighborSurface: String?
        if mergedIndex > 0, isMergeAllowed(between: segmentEdges[mergedIndex - 1], and: mergedEdge) {
            leftNeighborSurface = segmentEdges[mergedIndex - 1].surface
        } else {
            leftNeighborSurface = nil
        }
        let rightNeighborIndex = mergedIndex + 1
        let rightNeighborSurface: String?
        if rightNeighborIndex < segmentEdges.count,
           isMergeAllowed(between: mergedEdge, and: segmentEdges[rightNeighborIndex]) {
            rightNeighborSurface = segmentEdges[rightNeighborIndex].surface
        } else {
            rightNeighborSurface = nil
        }
        return (
            surface: mergedEdge.surface,
            leftNeighborSurface: leftNeighborSurface,
            rightNeighborSurface: rightNeighborSurface
        )
    }

    // Bottom-sheet split entry point: derives the target edge from the current merged
    // selection NSRange, delegates to `splitEdge`, then assembles the (surface, neighbors)
    // tuple the sheet's header refresh needs. As with merge, the post-split neighbors are
    // read straight from the returned indices — no fragile re-lookup.
    func applySplitSelection(offsetUTF16: Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let mergedRange = currentMergedSelectionNSRange(),
              let edgeIndex = segmentEdges.firstIndex(where: { edge in
                  let edgeRange = NSRange(edge.start..<edge.end, in: text)
                  return edgeRange.location == mergedRange.location && edgeRange.length == mergedRange.length
              }) else {
            return nil
        }

        guard let indices = splitEdge(
            at: edgeIndex,
            offsetUTF16: offsetUTF16,
            updateSelection: true
        ) else {
            return nil
        }

        let leftEdge = segmentEdges[indices.leftIndex]
        let rightEdge = segmentEdges[indices.rightIndex]
        let leftNeighborSurface: String?
        if indices.leftIndex > 0,
           isMergeAllowed(between: segmentEdges[indices.leftIndex - 1], and: leftEdge) {
            leftNeighborSurface = segmentEdges[indices.leftIndex - 1].surface
        } else {
            leftNeighborSurface = nil
        }
        return (
            surface: leftEdge.surface,
            leftNeighborSurface: leftNeighborSurface,
            rightNeighborSurface: rightEdge.surface
        )
    }

    // Segment-list merge entry point: a row in the list already knows its edge index, so
    // it delegates straight to `mergeEdges`. Selection is only updated in non-global mode
    // because the segment list dismisses its popover at the end and a fresh user tap will
    // re-establish selection anyway.
    func mergeSegmentFromSegmentList(at edgeIndex: Int, isMergingLeft: Bool) {
        _ = mergeEdges(
            at: edgeIndex,
            isMergingLeft: isMergingLeft,
            updateSelection: !shouldApplyChangesGlobally
        )
        SegmentLookupSheet.shared.dismissPopover()
    }

    // Segment-list split entry point: same pattern as `mergeSegmentFromSegmentList`.
    func splitSegmentFromSegmentList(at edgeIndex: Int, offsetUTF16: Int) {
        _ = splitEdge(
            at: edgeIndex,
            offsetUTF16: offsetUTF16,
            updateSelection: !shouldApplyChangesGlobally
        )
        SegmentLookupSheet.shared.dismissPopover()
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
