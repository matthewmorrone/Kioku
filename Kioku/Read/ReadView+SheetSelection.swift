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
    func preScrollSegmentForSheetVisibility(sourceView: UITextView?, tappedSegmentRect: CGRect?, animated: Bool = false) {
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

        sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: clampedOffsetY), animated: animated)
        sharedScrollOffsetY = clampedOffsetY
    }

    // Removes temporary sheet-induced overscroll once the segment action sheet is dismissed.
    func restoreScrollAfterSheetDismissal(sourceView: UITextView?, animated: Bool = false) {
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

        sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: clampedOffsetY), animated: animated)
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

    // Resolves the selected segment rect in text-view coordinates so sheet-visibility scroll checks can re-run after swipe navigation.
    func selectedSegmentRectInTextView(sourceView: UITextView, selectedLocation: Int) -> CGRect? {
        guard
            let tappedSegmentRange = segmentationRanges.first(where: { segmentRange in
                let nsRange = NSRange(segmentRange, in: text)
                return nsRange.location == selectedLocation && nsRange.length > 0
            })
        else {
            return nil
        }

        let segmentNSRange = NSRange(tappedSegmentRange, in: text)
        guard
            segmentNSRange.location != NSNotFound,
            segmentNSRange.length > 0,
            let rangeStart = sourceView.position(from: sourceView.beginningOfDocument, offset: segmentNSRange.location),
            let rangeEnd = sourceView.position(from: rangeStart, offset: segmentNSRange.length),
            let textRange = sourceView.textRange(from: rangeStart, to: rangeEnd)
        else {
            return nil
        }

        let selectedRect = sourceView.firstRect(for: textRange)
        guard selectedRect.isNull == false, selectedRect.isInfinite == false, selectedRect.isEmpty == false else {
            return nil
        }

        return selectedRect
    }

    // Builds unique reading candidates for the currently selected kanji-containing segment(s) for future sheet UI usage.
    func uniqueReadingsForCurrentSelectedKanjiSegment() -> [String] {
        guard let selectedBounds = selectedMergedEdgeBounds else {
            return []
        }

        let selectedEdges = Array(segmentationEdges[selectedBounds])
        let containsKanji = selectedEdges.contains { edge in
            ScriptClassifier.containsKanji(edge.surface)
        }
        guard containsKanji else {
            return []
        }

        var readingCandidates: [String] = []
        var seenReadings = Set<String>()

        // Appends a reading while keeping insertion order stable and unique.
        func appendReading(_ reading: String?) {
            guard let reading, reading.isEmpty == false, seenReadings.contains(reading) == false else {
                return
            }

            seenReadings.insert(reading)
            readingCandidates.append(reading)
        }

        let selectedStart = selectedEdges.first?.start
        let selectedEnd = selectedEdges.last?.end
        if let selectedStart, let selectedEnd, selectedStart < selectedEnd {
            let mergedSurface = String(text[selectedStart..<selectedEnd])
            appendReading(readingBySurface[mergedSurface])
            if let mergedReadingCandidates = readingCandidatesBySurface[mergedSurface] {
                for reading in mergedReadingCandidates {
                    appendReading(reading)
                }
            }
        }

        for edge in selectedEdges {
            appendReading(readingBySurface[edge.surface])
            if let surfaceReadingCandidates = readingCandidatesBySurface[edge.surface] {
                for reading in surfaceReadingCandidates {
                    appendReading(reading)
                }
            }

            appendReading(readingBySurface[edge.lemma])
            if let lemmaReadingCandidates = readingCandidatesBySurface[edge.lemma] {
                for reading in lemmaReadingCandidates {
                    appendReading(reading)
                }
            }
        }

        return readingCandidates
    }

    // Captures lattice edges enclosed by the currently selected merged segment span for future sheet UI usage.
    func sublatticeEdgesForCurrentSelectedSegment() -> [LatticeEdge] {
        guard let selectedBounds = selectedMergedEdgeBounds else {
            return []
        }

        let selectedStart = segmentationEdges[selectedBounds.lowerBound].start
        let selectedEnd = segmentationEdges[selectedBounds.upperBound].end

        return segmentationLatticeEdges
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
    }
}