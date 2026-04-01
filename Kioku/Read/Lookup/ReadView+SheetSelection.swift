import SwiftUI
import UIKit

// Describes the viewport and selection geometry used to plan sheet-visibility scrolling.
struct ReadViewSheetVisibilityScrollContext: Equatable {
    let currentOffsetY: CGFloat
    let minOffsetY: CGFloat
    let maxOffsetY: CGFloat
    let viewportHeight: CGFloat
    let adjustedTopInset: CGFloat
    let selectedSegmentRectInContent: CGRect
    let estimatedSheetHeight: CGFloat
    let estimatedRelativeCoverage: CGFloat
    let maximumCoveredHeightRatio: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
}

// Describes one sheet-visibility scroll adjustment computed from pure geometry.
struct ReadViewSheetVisibilityScrollAdjustment: Equatable {
    let targetOffsetY: CGFloat
    let usesTemporaryBottomOverscroll: Bool
}

// Computes scroll adjustments needed to keep the selected segment visible while the lookup sheet is active.
enum ReadViewSheetVisibilityScrollPlanner {
    static func adjustment(for context: ReadViewSheetVisibilityScrollContext) -> ReadViewSheetVisibilityScrollAdjustment? {
        let expectedCoveredHeight = min(
            max(
                context.estimatedSheetHeight,
                context.viewportHeight * context.estimatedRelativeCoverage
            ),
            context.viewportHeight * context.maximumCoveredHeightRatio
        )
        let visibleTopLimitY = max(context.topPadding, context.adjustedTopInset + context.topPadding)
        let coveredTopY = context.viewportHeight - expectedCoveredHeight
        let visibleBottomLimitY = max(visibleTopLimitY, coveredTopY - context.bottomPadding)

        let visibleSegmentRect = context.selectedSegmentRectInContent.offsetBy(
            dx: 0,
            dy: -context.currentOffsetY
        )

        var targetOffsetY = context.currentOffsetY
        if visibleSegmentRect.minY < visibleTopLimitY {
            targetOffsetY += visibleSegmentRect.minY - visibleTopLimitY
        } else if visibleSegmentRect.maxY > visibleBottomLimitY {
            targetOffsetY += visibleSegmentRect.maxY - visibleBottomLimitY
        } else {
            return nil
        }

        targetOffsetY = max(targetOffsetY, context.minOffsetY)
        guard abs(targetOffsetY - context.currentOffsetY) > 0.5 else {
            return nil
        }

        return ReadViewSheetVisibilityScrollAdjustment(
            targetOffsetY: targetOffsetY,
            usesTemporaryBottomOverscroll: targetOffsetY > context.maxOffsetY + 0.5
        )
    }

    static func dismissalTargetOffsetY(currentOffsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat) -> CGFloat? {
        let clampedOffsetY = min(max(currentOffsetY, minOffsetY), maxOffsetY)
        guard abs(clampedOffsetY - currentOffsetY) > 0.5 else {
            return nil
        }

        return clampedOffsetY
    }
}

// Hosts sheet-selection and sheet-driven scroll helpers for the read screen.
extension ReadView {
    private var sheetVisibilityScrollAnimationDuration: TimeInterval { 0.18 }

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

    // Animates content-offset changes with a completion callback so sheet presentation/dismissal can be sequenced cleanly.
    func animateContentOffset(
        for sourceView: UITextView,
        targetOffsetY: CGFloat,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        if animated == false {
            sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: targetOffsetY), animated: false)
            completion?()
            return
        }

        UIView.animate(
            withDuration: sheetVisibilityScrollAnimationDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            sourceView.contentOffset = CGPoint(x: sourceView.contentOffset.x, y: targetOffsetY)
        } completion: { _ in
            completion?()
        }
    }

    // Scrolls only enough to keep the selected segment inside the visible band above the lookup sheet.
    func preScrollSegmentForSheetVisibility(
        sourceView: UITextView?,
        tappedSegmentRect: CGRect?,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        guard let sourceView, let tappedSegmentRect else {
            completion?()
            return
        }

        let minOffsetY = -sourceView.adjustedContentInset.top
        let maxContentOffsetY = max(
            minOffsetY,
            sourceView.contentSize.height - sourceView.bounds.height + sourceView.adjustedContentInset.bottom
        )
        let context = ReadViewSheetVisibilityScrollContext(
            currentOffsetY: sourceView.contentOffset.y,
            minOffsetY: minOffsetY,
            maxOffsetY: maxContentOffsetY,
            viewportHeight: sourceView.bounds.height,
            adjustedTopInset: sourceView.adjustedContentInset.top,
            selectedSegmentRectInContent: tappedSegmentRect,
            estimatedSheetHeight: 360,
            estimatedRelativeCoverage: 0.64,
            maximumCoveredHeightRatio: 0.5,
            topPadding: 24,
            bottomPadding: 16
        )
        guard let adjustment = ReadViewSheetVisibilityScrollPlanner.adjustment(for: context) else {
            sharedScrollOffsetY = sourceView.contentOffset.y
            completion?()
            return
        }

        sharedScrollOffsetY = adjustment.targetOffsetY
        animateContentOffset(
            for: sourceView,
            targetOffsetY: adjustment.targetOffsetY,
            animated: animated,
            completion: completion
        )
    }

    // Removes temporary sheet-induced overscroll once the segment action sheet is dismissed.
    func restoreScrollAfterSheetDismissal(
        sourceView: UITextView?,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        guard let sourceView else {
            completion?()
            return
        }

        let minOffsetY = -sourceView.adjustedContentInset.top
        let maxContentOffsetY = max(
            minOffsetY,
            sourceView.contentSize.height - sourceView.bounds.height + sourceView.adjustedContentInset.bottom
        )
        guard let dismissalTargetOffsetY = ReadViewSheetVisibilityScrollPlanner.dismissalTargetOffsetY(
            currentOffsetY: sourceView.contentOffset.y,
            minOffsetY: minOffsetY,
            maxOffsetY: maxContentOffsetY
        ) else {
            sharedScrollOffsetY = sourceView.contentOffset.y
            completion?()
            return
        }

        sharedScrollOffsetY = dismissalTargetOffsetY
        animateContentOffset(
            for: sourceView,
            targetOffsetY: dismissalTargetOffsetY,
            animated: animated,
            completion: completion
        )
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
        if let mergedData = surfaceReadingData[mergedSurface] {
            for reading in mergedData.readings {
                appendReading(reading)
            }
        }

        // For multi-edge merges, include per-edge surface readings (not lemma readings).
        for edge in selectedEdges where edge.surface != mergedSurface {
            if let lexicon {
                appendReading(lexicon.reading(surface: edge.surface))
            }
            if let edgeData = surfaceReadingData[edge.surface] {
                for reading in edgeData.readings {
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

    // Returns the base lemma and inflection chain for the current selection when it is a conjugated/inflected form.
    // Returns nil when the surface matches its own lemma (i.e. no inflection occurred).
    func lemmaInfoForCurrentSelectedSegment() -> (lemma: String, chain: [String])? {
        guard let selectedBounds, let lexicon else { return nil }
        let selectedEdges = Array(segmentEdges[selectedBounds])
        guard let start = selectedEdges.first?.start, let end = selectedEdges.last?.end else { return nil }
        let surface = String(text[start..<end])
        let info = lexicon.inflectionInfo(surface: surface)
        // print("[lemmaInfo] surface=\(surface) info=\(info.map { "\($0.lemma) chain=\($0.chain)" } ?? "nil")")
        guard let info, info.lemma != surface else { return nil }
        return (lemma: info.lemma, chain: info.chain)
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

        if let data = surfaceReadingData[surface]?.frequencyByReading {
            return data
        }

        // Inflected surfaces (e.g. 話していた) won't appear in the frequency map, which is
        // keyed by dictionary forms. lemma() returns only max-depth candidates (true base forms).
        guard let lexicon else {
            return nil
        }

        for lemma in lexicon.lemma(surface: surface) {
            if let data = surfaceReadingData[lemma]?.frequencyByReading {
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

    // Returns the merged surface text for the currently selected segment bounds, or nil when nothing is selected.
    func currentSelectedSurface() -> String? {
        guard let bounds = selectedBounds,
              bounds.lowerBound < segmentEdges.count,
              bounds.upperBound < segmentEdges.count else { return nil }
        let start = segmentEdges[bounds.lowerBound].start
        let end = segmentEdges[bounds.upperBound].end
        let surface = String(text[start..<end])
        return surface.isEmpty ? nil : surface
    }
}
