import SwiftUI
import UIKit

// Hosts sheet-selection and sheet-driven scroll helpers for the read screen.
extension ReadView {
    // Clears selected segment state when segment action UI is dismissed by user interaction.
    func clearSelectedSegmentStateAfterPopoverDismissal() {
        selectedSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedBounds = nil
    }

    // Resolves segment surface text for a selected location without dictionary lookup overhead.
    func surfaceForSegment(at selectedLocation: Int) -> String? {
        guard
            let tappedSegmentRange = segmentRanges.first(where: { segmentRange in
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
        guard let currentBounds = selectedBounds ?? selectedSegmentLocation.flatMap({ location in
            initialMergedEdgeBounds(for: location)
        }) else {
            return nil
        }

        let step = isMovingForward ? 1 : -1
        var candidateIndex = isMovingForward ? currentBounds.upperBound + 1 : currentBounds.lowerBound - 1

        while candidateIndex >= 0 && candidateIndex < segmentEdges.count {
            let candidateEdge = segmentEdges[candidateIndex]
            if shouldIgnoreSegmentForDefinitionLookup(candidateEdge.surface) == false {
                let candidateRange = NSRange(candidateEdge.start..<candidateEdge.end, in: text)
                guard candidateRange.location != NSNotFound, candidateRange.length > 0 else {
                    return nil
                }

                selectedBounds = candidateIndex...candidateIndex
                selectedSegmentLocation = candidateRange.location
                selectedHighlightRangeOverride = candidateRange
                // debugPrintLatticeSectionForCurrentSelection(at: candidateRange.location)

                let leftNeighborSurface = candidateIndex > 0 ? segmentEdges[candidateIndex - 1].surface : nil
                let rightNeighborIndex = candidateIndex + 1
                let rightNeighborSurface = rightNeighborIndex < segmentEdges.count ? segmentEdges[rightNeighborIndex].surface : nil
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
            let tappedSegmentRange = segmentRanges.first(where: { segmentRange in
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

    // Builds unique reading candidates for the currently selected segment(s), leading with the lexicon reading so it matches the LEXICON section.
    func uniqueReadingsForCurrentSelectedKanjiSegment() -> [String] {
        guard let selectedBounds else {
            return []
        }

        let selectedEdges = Array(segmentEdges[selectedBounds])
        guard let selectedStart = selectedEdges.first?.start,
              let selectedEnd = selectedEdges.last?.end,
              selectedStart < selectedEnd else {
            return []
        }

        let mergedSurface = String(text[selectedStart..<selectedEnd])

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

        // Lead with the lexicon reading for the merged surface so this matches the LEXICON section's "reading:" line.
        if let lexicon {
            appendReading(lexicon.reading(surface: mergedSurface))
        }

        // Additional candidates for the merged surface only — no lemma forms.
        appendReading(readingBySurface[mergedSurface])
        if let mergedReadingCandidates = readingCandidatesBySurface[mergedSurface] {
            for reading in mergedReadingCandidates {
                appendReading(reading)
            }
        }

        // For multi-edge merges, include per-edge surface readings (not lemma readings).
        for edge in selectedEdges where edge.surface != mergedSurface {
            if let lexicon {
                appendReading(lexicon.reading(surface: edge.surface))
            }
            appendReading(readingBySurface[edge.surface])
            if let surfaceReadingCandidates = readingCandidatesBySurface[edge.surface] {
                for reading in surfaceReadingCandidates {
                    appendReading(reading)
                }
            }
        }

        return readingCandidates
    }

    // Builds a formatted debug string showing key Lexicon method outputs for the currently selected surface.
    func lexiconDebugInfoForCurrentSelectedSegment() -> String {
        guard let selectedBounds else {
            return ""
        }

        guard let lexicon else {
            return "(Lexicon unavailable)"
        }

        let selectedEdges = Array(segmentEdges[selectedBounds])
        guard let startIndex = selectedEdges.first?.start, let endIndex = selectedEdges.last?.end else {
            return ""
        }

        let surface = String(text[startIndex..<endIndex])
        var lines: [String] = []

        lines.append("reading: \(lexicon.reading(surface: surface))")

        let lemmas = lexicon.lemma(surface: surface)
        lines.append("lemma: [\(lemmas.joined(separator: ", "))]")

        let normalized = lexicon.normalize(surface: surface)
        let normalizedStr = normalized.map { "\($0.lemma)(\($0.reading))" }.joined(separator: ", ")
        lines.append("normalize: [\(normalizedStr)]")

        if let (inflLemma, inflChain) = lexicon.inflectionInfo(surface: surface) {
            let chainStr = inflChain.isEmpty ? "—" : inflChain.joined(separator: " → ")
            lines.append("inflectionInfo: \(inflLemma) via \(chainStr)")
        } else {
            lines.append("inflectionInfo: nil")
        }

        if let transitions = lexicon.inflectionTransitions(surface: surface), transitions.isEmpty == false {
            let transStr = transitions.map { "\($0.kanaIn)→\($0.kanaOut)" }.joined(separator: ", ")
            lines.append("transitions: \(transStr)")
        }

        let chain = lexicon.inflectionChain(surface: surface)
        lines.append("inflectionChain: [\(chain.joined(separator: " → "))]")

        let resolved = lexicon.resolve(surface: surface)
        let resolvedStr = resolved.prefix(5).map { "\($0.lexeme)(\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
        lines.append("resolve(top 5): [\(resolvedStr)]")

        return lines.joined(separator: "\n")
    }

    // Returns the reading→FrequencyData map for the currently selected segment surface,
    // or nil if no frequency data is available. The inner dict is keyed by reading (kana text)
    // so callers can look up frequency for whichever reading is currently displayed.
    // Falls back to deinflected lemma forms when the surface has no direct frequency entry.
    func frequencyRankForCurrentSelectedSegment() -> [String: FrequencyData]? {
        guard let selectedBounds else {
            return nil
        }

        let startIndex = segmentEdges[selectedBounds.lowerBound].start
        let endIndex = segmentEdges[selectedBounds.upperBound].end
        let surface = String(text[startIndex..<endIndex])

        if let data = frequencyDataBySurface[surface] {
            return data
        }

        // Inflected surfaces (e.g. 話していた) won't appear in the frequency map, which is
        // keyed by dictionary forms. lemma() returns only max-depth candidates (true base forms).
        guard let lexicon else {
            return nil
        }

        for lemma in lexicon.lemma(surface: surface) {
            if let data = frequencyDataBySurface[lemma] {
                return data
            }
        }

        return nil
    }

    // Captures lattice edges enclosed by the currently selected merged segment span for future sheet UI usage.
    func sublatticeEdgesForCurrentSelectedSegment() -> [LatticeEdge] {
        guard let selectedBounds else {
            return []
        }

        let selectedStart = segmentEdges[selectedBounds.lowerBound].start
        let selectedEnd = segmentEdges[selectedBounds.upperBound].end

        return Lattice.sectionEdges(
            from: segmentLatticeEdges,
            in: text,
            selectedStart: selectedStart,
            selectedEnd: selectedEnd
        )
    }
}
