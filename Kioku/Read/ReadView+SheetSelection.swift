import SwiftUI
import UIKit

// Hosts sheet-selection and sheet-driven scroll helpers for the read screen.
extension ReadView {
    // Clears selected segment state when segment action UI is dismissed by user interaction.
    func clearSelectedSegmentStateAfterPopoverDismissal() {
        selectedSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedMergedEdgeBounds = nil
    }

    // Resolves segment surface text for a selected location without dictionary lookup overhead.
    func surfaceForSegment(at selectedLocation: Int) -> String? {
        guard
            let tappedSegmentRange = segmentationRanges.first(where: { segmentRange in
                let nsRange = NSRange(segmentRange, in: text)
                return nsRange.location == selectedLocation && nsRange.length > 0
            })
        else {
            return nil
        }

        let tappedSurface = String(text[tappedSegmentRange])
        if shouldIgnoreSegmentForDefinitionLookup(tappedSurface) {
            return nil
        }

        return tappedSurface
    }

    // Scrolls only enough to keep the selected segment above the incoming sheet.
    func preScrollSegmentForSheetVisibility(sourceView: UITextView?, tappedSegmentRect: CGRect?) {
        guard let sourceView, let tappedSegmentRect else {
            return
        }

        // Treats tap geometry as content-space coordinates so scroll math uses the segment's visible position.
        let normalizedSegmentRect = tappedSegmentRect.offsetBy(dx: 0, dy: -sourceView.contentOffset.y)

        let estimatedSheetHeight: CGFloat = 360
        let estimatedRelativeCoverage = sourceView.bounds.height * 0.64
        let expectedCoveredHeight = max(estimatedSheetHeight, estimatedRelativeCoverage)
        let coveredTopY = sourceView.bounds.height - expectedCoveredHeight

        // Keeps already-visible segments fixed and only moves lower ones enough to clear the sheet edge.
        let visibilityPadding: CGFloat = 16
        let visibleBottomLimitY = max(24, coveredTopY - visibilityPadding)
        let requiredScrollDeltaY = max(0, normalizedSegmentRect.maxY - visibleBottomLimitY)
        guard requiredScrollDeltaY > 0.5 else {
            sharedScrollOffsetY = sourceView.contentOffset.y
            return
        }

        let requestedOffsetY = sourceView.contentOffset.y + requiredScrollDeltaY
        let minOffsetY = -sourceView.adjustedContentInset.top
        let maxContentOffsetY = max(
            minOffsetY,
            sourceView.contentSize.height - sourceView.bounds.height + sourceView.adjustedContentInset.bottom
        )
        let overscrollAllowance: CGFloat = expectedCoveredHeight * 0.5
        let clampedOffsetY = min(max(requestedOffsetY, minOffsetY), maxContentOffsetY + overscrollAllowance)

        sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: clampedOffsetY), animated: true)
        sharedScrollOffsetY = clampedOffsetY
    }

    // Removes temporary sheet-induced overscroll once the segment action sheet is dismissed.
    func restoreScrollAfterSheetDismissal(sourceView: UITextView?) {
        guard let sourceView else {
            return
        }

        let minOffsetY = -sourceView.adjustedContentInset.top
        let maxContentOffsetY = max(minOffsetY, sourceView.contentSize.height - sourceView.bounds.height + sourceView.adjustedContentInset.bottom)
        let clampedOffsetY = min(max(sharedScrollOffsetY, minOffsetY), maxContentOffsetY)
        guard abs(clampedOffsetY - sourceView.contentOffset.y) > 0.5 else {
            sharedScrollOffsetY = clampedOffsetY
            return
        }

        sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: clampedOffsetY), animated: true)
        sharedScrollOffsetY = clampedOffsetY
    }

    // Moves sheet selection to the previous or next selectable segment and returns refreshed sheet payload.
    func moveSelectedSegmentSelection(isMovingForward: Bool) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let currentBounds = selectedMergedEdgeBounds ?? selectedSegmentLocation.flatMap({ location in
            initialMergedEdgeBounds(for: location)
        }) else {
            return nil
        }

        let step = isMovingForward ? 1 : -1
        var candidateIndex = isMovingForward ? currentBounds.upperBound + 1 : currentBounds.lowerBound - 1

        while candidateIndex >= 0 && candidateIndex < segmentationEdges.count {
            let candidateEdge = segmentationEdges[candidateIndex]
            if shouldIgnoreSegmentForDefinitionLookup(candidateEdge.surface) == false {
                let candidateRange = NSRange(candidateEdge.start..<candidateEdge.end, in: text)
                guard candidateRange.location != NSNotFound, candidateRange.length > 0 else {
                    return nil
                }

                selectedMergedEdgeBounds = candidateIndex...candidateIndex
                selectedSegmentLocation = candidateRange.location
                selectedHighlightRangeOverride = candidateRange
                // debugPrintLatticeSectionForCurrentSelection(at: candidateRange.location)

                let leftNeighborSurface = candidateIndex > 0 ? segmentationEdges[candidateIndex - 1].surface : nil
                let rightNeighborIndex = candidateIndex + 1
                let rightNeighborSurface = rightNeighborIndex < segmentationEdges.count ? segmentationEdges[rightNeighborIndex].surface : nil
                return (
                    surface: candidateEdge.surface,
                    leftNeighborSurface: leftNeighborSurface,
                    rightNeighborSurface: rightNeighborSurface
                )
            }

            candidateIndex += step
        }

        return nil
    }
}