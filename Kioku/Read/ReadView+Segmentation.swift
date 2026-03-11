import SwiftUI
import UIKit

// Hosts segmentation and token action helpers for the read screen.
extension ReadView {
    // Clears note-backed token range overrides and restores computed segmentation from the segmenter.
    func resetTokenSegmentationToComputed() {
        tokenRanges = nil
        illegalMergeBoundaryLocation = nil
        illegalMergeFlashTask?.cancel()
        selectedSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedMergedEdgeBounds = nil
        SegmentDefinitionPopoverPresenter.shared.dismissPopover()

        if readResourcesReady && isEditMode == false {
            refreshSegmentationRanges()
        } else {
            segmentationEdges = []
            segmentationRanges = []
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
        }

        persistCurrentNoteIfNeeded()
    }

    // Merges one token with its immediate neighbor from the token list screen.
    func mergeSegmentFromTokenList(at edgeIndex: Int, isMergingLeft: Bool) {
        guard segmentationEdges.indices.contains(edgeIndex) else {
            return
        }

        let mergeBounds: ClosedRange<Int>
        let sourceLeftSurface: String
        let sourceRightSurface: String
        
        if isMergingLeft {
            guard edgeIndex > 0 else {
                return
            }
            let leftEdge = segmentationEdges[edgeIndex - 1]
            let rightEdge = segmentationEdges[edgeIndex]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return
            }
            mergeBounds = (edgeIndex - 1)...edgeIndex
            sourceLeftSurface = leftEdge.surface
            sourceRightSurface = rightEdge.surface
        } else {
            guard edgeIndex + 1 < segmentationEdges.count else {
                return
            }
            let leftEdge = segmentationEdges[edgeIndex]
            let rightEdge = segmentationEdges[edgeIndex + 1]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return
            }
            mergeBounds = edgeIndex...(edgeIndex + 1)
            sourceLeftSurface = leftEdge.surface
            sourceRightSurface = rightEdge.surface
        }

        var updatedEdges = segmentationEdges
        
        // Applies merge globally to all matching token pairs when enabled.
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
                        let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface, lemma: mergedSurface)
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
            let mergedStart = segmentationEdges[mergeBounds.lowerBound].start
            let mergedEnd = segmentationEdges[mergeBounds.upperBound].end
            let mergedSurface = String(text[mergedStart..<mergedEnd])
            let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface, lemma: mergedSurface)
            updatedEdges.replaceSubrange(mergeBounds, with: [mergedEdge])
        }
        
        applySegmentationEdges(updatedEdges, persistOverride: true)

        if !shouldApplyChangesGlobally {
            let mergedIndex = mergeBounds.lowerBound
            let mergedStart = segmentationEdges[mergeBounds.lowerBound].start
            let mergedEnd = segmentationEdges[mergeBounds.upperBound].end
            selectedMergedEdgeBounds = mergedIndex...mergedIndex
            let mergedNSRange = NSRange(mergedStart..<mergedEnd, in: text)
            selectedSegmentLocation = mergedNSRange.location
            selectedHighlightRangeOverride = mergedNSRange
        }
        SegmentDefinitionPopoverPresenter.shared.dismissPopover()
    }

    // Splits one token at a UTF-16 boundary selected from the token list screen.
    func splitSegmentFromTokenList(at edgeIndex: Int, offsetUTF16: Int) {
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
        
        // Applies split globally to all matching tokens when enabled.
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

    // Rebuilds greedy segmentation ranges used by alternating segment colors in the editor.
    func refreshSegmentationRanges() {
        guard readResourcesReady else {
            illegalMergeBoundaryLocation = nil
            illegalMergeFlashTask?.cancel()
            furiganaComputationTask?.cancel()
            segmentationEdges = []
            segmentationRanges = []
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedMergedEdgeBounds = nil
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            return
        }

        let baseEdges = segmenter.longestMatchEdges(for: text)
        let refreshedEdges: [LatticeEdge]
        if let tokenRanges,
           let overriddenEdges = edgesFromTokenRanges(tokenRanges, in: text) {
            refreshedEdges = overriddenEdges
        } else {
            if tokenRanges != nil {
                tokenRanges = nil
                persistCurrentNoteIfNeeded()
            }
            refreshedEdges = baseEdges
        }

        segmentationEdges = refreshedEdges
        segmentationRanges = refreshedEdges.map { edge in
            edge.start..<edge.end
        }

        let refreshedTokenRanges = buildTokenRanges(from: refreshedEdges)
        if tokenRanges != refreshedTokenRanges {
            tokenRanges = refreshedTokenRanges
            persistCurrentNoteIfNeeded()
        }

        // Clears stale selection if the tapped segment no longer exists after recomputing ranges.
        if let selectedSegmentLocation {
            let hasSelectedSegment = segmentationRanges.contains { segmentRange in
                let nsRange = NSRange(segmentRange, in: text)
                return nsRange.location == selectedSegmentLocation && nsRange.length > 0
            }
            if hasSelectedSegment == false {
                self.selectedSegmentLocation = nil
                selectedHighlightRangeOverride = nil
                selectedMergedEdgeBounds = nil
                SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            }
        }

        scheduleFuriganaGeneration(for: text, edges: refreshedEdges)
    }

    // Updates selection state and shows a UIKit popover with the highest-priority dictionary definition for the tapped segment.
    func handleReadModeSegmentTap(_ tappedSegmentLocation: Int?, tappedSegmentRect: CGRect?, sourceView: UITextView?) {
        guard let tappedSegmentLocation else {
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedMergedEdgeBounds = nil
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            return
        }

        if selectedSegmentLocation == tappedSegmentLocation {
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedMergedEdgeBounds = nil
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            return
        }

        selectedSegmentLocation = tappedSegmentLocation
        selectedHighlightRangeOverride = nil
        selectedMergedEdgeBounds = initialMergedEdgeBounds(for: tappedSegmentLocation)

        let adjacentSurfaces = adjacentSegmentSurfaces(for: tappedSegmentLocation)

        if prefersSheetDirectSegmentActions {
            guard let segmentSurface = surfaceForSegment(at: tappedSegmentLocation) else {
                SegmentDefinitionPopoverPresenter.shared.dismissPopover()
                return
            }

            preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: tappedSegmentRect)
            SegmentDefinitionPopoverPresenter.shared.presentSheet(
                surface: segmentSurface,
                leftNeighborSurface: adjacentSurfaces.left,
                rightNeighborSurface: adjacentSurfaces.right,
                onMergeLeft: {
                    mergeAdjacentSegment(isMergingLeft: true)
                },
                onMergeRight: {
                    mergeAdjacentSegment(isMergingLeft: false)
                },
                onSplitApply: { splitOffset in
                    applySplitSelection(offsetUTF16: splitOffset)
                },
                onDismiss: {
                    clearSelectedSegmentStateAfterPopoverDismissal()
                    restoreScrollAfterSheetDismissal(sourceView: sourceView)
                }
            )
            return
        }

        guard let definitionPayload = definitionPayloadForSelectedSegment(at: tappedSegmentLocation) else {
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            return
        }

        guard let sourceView, let tappedSegmentRect else {
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            return
        }

        SegmentDefinitionPopoverPresenter.shared.presentPopover(
            definition: definitionPayload.definition,
            surface: definitionPayload.surface,
            leftNeighborSurface: adjacentSurfaces.left,
            rightNeighborSurface: adjacentSurfaces.right,
            onMergeLeft: {
                mergeAdjacentSegment(isMergingLeft: true)
            },
            onMergeRight: {
                mergeAdjacentSegment(isMergingLeft: false)
            },
            onSplitApply: { splitOffset in
                applySplitSelection(offsetUTF16: splitOffset)
            },
            onDismiss: {
                clearSelectedSegmentStateAfterPopoverDismissal()
            },
            sourceView: sourceView,
            sourceRect: tappedSegmentRect
        )
    }

    // Clears selected token state when token action UI is dismissed by user interaction.
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

    // Scrolls the selected segment line to a stable position midway between the read area top and sheet top.
    func preScrollSegmentForSheetVisibility(sourceView: UITextView?, tappedSegmentRect: CGRect?) {
        guard let sourceView, let tappedSegmentRect else {
            return
        }

        // Treats tap geometry as content-space coordinates so scroll math uses the token's visible position.
        let normalizedSegmentRect = tappedSegmentRect.offsetBy(dx: 0, dy: -sourceView.contentOffset.y)

        let estimatedSheetHeight: CGFloat = 360
        let estimatedRelativeCoverage = sourceView.bounds.height * 0.64
        let expectedCoveredHeight = max(estimatedSheetHeight, estimatedRelativeCoverage)
        let coveredTopY = sourceView.bounds.height - expectedCoveredHeight

        let targetLineMidY = max(24, coveredTopY * 0.5)
        let requestedOffsetY = sourceView.contentOffset.y + (normalizedSegmentRect.midY - targetLineMidY)
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

    // Removes temporary sheet-induced overscroll once the token action sheet is dismissed.
    func restoreScrollAfterSheetDismissal(sourceView: UITextView?) {
        guard let sourceView else {
            return
        }

        let minOffsetY = -sourceView.adjustedContentInset.top
        let maxContentOffsetY = max(
            minOffsetY,
            sourceView.contentSize.height - sourceView.bounds.height + sourceView.adjustedContentInset.bottom
        )
        let clampedOffsetY = min(max(sharedScrollOffsetY, minOffsetY), maxContentOffsetY)
        guard abs(clampedOffsetY - sourceView.contentOffset.y) > 0.5 else {
            sharedScrollOffsetY = clampedOffsetY
            return
        }

        sourceView.setContentOffset(CGPoint(x: sourceView.contentOffset.x, y: clampedOffsetY), animated: true)
        sharedScrollOffsetY = clampedOffsetY
    }

    // Resolves the tapped segment surface and the best-ordered gloss from dictionary results.
    func definitionPayloadForSelectedSegment(at selectedLocation: Int) -> (surface: String, definition: String)? {
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

        let matchingEdge = segmentationEdges.first { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == selectedLocation && edgeNSRange.length > 0
        }

        let lookupCandidates = orderedLookupCandidates(surface: tappedSurface, lemma: matchingEdge?.lemma)
        for lookupCandidate in lookupCandidates {
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(lookupCandidate) ? .kanjiAndKana : .kanaOnly
            do {
                guard let entries = try dictionaryStore?.lookup(surface: lookupCandidate, mode: lookupMode) else {
                    continue
                }

                if let mostLikelyDefinition = mostLikelyDefinition(from: entries) {
                    return (surface: tappedSurface, definition: mostLikelyDefinition)
                }
            } catch {
                // Keeps tap interaction resilient if dictionary access fails for a specific lookup candidate.
                continue
            }
        }

        return nil
    }

    // Builds de-duplicated lookup candidates in priority order: tapped surface first, then lemma fallback.
    func orderedLookupCandidates(surface: String, lemma: String?) -> [String] {
        var candidates: [String] = []

        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSurface.isEmpty == false {
            candidates.append(trimmedSurface)
        }

        if let lemma {
            let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLemma.isEmpty == false && trimmedLemma != trimmedSurface {
                candidates.append(trimmedLemma)
            }
        }

        return candidates
    }

    // Extracts the most likely dictionary gloss from already-prioritized entry ordering.
    func mostLikelyDefinition(from entries: [DictionaryEntry]) -> String? {
        var candidateGlosses: [(gloss: String, entryIndex: Int, senseIndex: Int, glossIndex: Int)] = []

        for (entryIndex, entry) in entries.enumerated() {
            for (senseIndex, sense) in entry.senses.enumerated() {
                for (glossIndex, gloss) in sense.glosses.enumerated() {
                    let trimmedGloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedGloss.isEmpty {
                        continue
                    }

                    candidateGlosses.append(
                        (
                            gloss: trimmedGloss,
                            entryIndex: entryIndex,
                            senseIndex: senseIndex,
                            glossIndex: glossIndex
                        )
                    )
                }
            }
        }

        guard candidateGlosses.isEmpty == false else {
            return nil
        }

        let preferredDefinition = candidateGlosses.min { lhs, rhs in
            if lhs.gloss.count != rhs.gloss.count {
                return lhs.gloss.count < rhs.gloss.count
            }

            if lhs.entryIndex != rhs.entryIndex {
                return lhs.entryIndex < rhs.entryIndex
            }

            if lhs.senseIndex != rhs.senseIndex {
                return lhs.senseIndex < rhs.senseIndex
            }

            return lhs.glossIndex < rhs.glossIndex
        }

        return preferredDefinition?.gloss
    }

    // Resolves the initial merged edge bounds for the currently selected segment location.
    func initialMergedEdgeBounds(for selectedLocation: Int) -> ClosedRange<Int>? {
        guard let selectedIndex = segmentationEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == selectedLocation && edgeNSRange.length > 0
        }) else {
            return nil
        }

        return selectedIndex...selectedIndex
    }

    // Resolves immediate left and right segment surfaces around the active merged edge bounds.
    func adjacentSegmentSurfaces(for selectedLocation: Int) -> (left: String?, right: String?) {
        let activeBounds = selectedMergedEdgeBounds ?? initialMergedEdgeBounds(for: selectedLocation)
        guard let activeBounds else {
            return (left: nil, right: nil)
        }

        let leftSurface = activeBounds.lowerBound > 0 ? segmentationEdges[activeBounds.lowerBound - 1].surface : nil
        let rightIndex = activeBounds.upperBound + 1
        let rightSurface = rightIndex < segmentationEdges.count ? segmentationEdges[rightIndex].surface : nil
        return (left: leftSurface, right: rightSurface)
    }

    // Applies a merge against the current merged bounds and returns updated popover payload fields.
    func mergeAdjacentSegment(isMergingLeft: Bool) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)? {
        guard let currentBounds = selectedMergedEdgeBounds ?? selectedSegmentLocation.flatMap({ location in
            initialMergedEdgeBounds(for: location)
        }) else {
            return nil
        }

        let nextBounds: ClosedRange<Int>
        if isMergingLeft {
            guard currentBounds.lowerBound > 0 else {
                return nil
            }
            let leftEdge = segmentationEdges[currentBounds.lowerBound - 1]
            let rightEdge = segmentationEdges[currentBounds.lowerBound]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            nextBounds = (currentBounds.lowerBound - 1)...currentBounds.upperBound
        } else {
            guard currentBounds.upperBound + 1 < segmentationEdges.count else {
                return nil
            }
            let leftEdge = segmentationEdges[currentBounds.upperBound]
            let rightEdge = segmentationEdges[currentBounds.upperBound + 1]
            guard isMergeAllowed(between: leftEdge, and: rightEdge) else {
                flashIllegalMergeBoundary(between: leftEdge, and: rightEdge)
                return nil
            }
            nextBounds = currentBounds.lowerBound...(currentBounds.upperBound + 1)
        }

        let mergedStart = segmentationEdges[nextBounds.lowerBound].start
        let mergedEnd = segmentationEdges[nextBounds.upperBound].end
        let mergedSurface = String(text[mergedStart..<mergedEnd])
        let mergedEdge = LatticeEdge(start: mergedStart, end: mergedEnd, surface: mergedSurface, lemma: mergedSurface)
        let sourceLeftSurface = segmentationEdges[nextBounds.lowerBound].surface
        let sourceRightSurface = segmentationEdges[nextBounds.upperBound].surface

        var updatedEdges = segmentationEdges
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
                                surface: globalMergedSurface,
                                lemma: globalMergedSurface
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

        applySegmentationEdges(updatedEdges, persistOverride: true)

        guard let mergedIndex = updatedEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == NSRange(mergedStart..<mergedEnd, in: text).location && edge.surface == mergedSurface
        }) else {
            return nil
        }

        selectedMergedEdgeBounds = mergedIndex...mergedIndex
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

        guard let mergedEdgeIndex = segmentationEdges.firstIndex(where: { edge in
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
            surface: leftSurface,
            lemma: leftSurface
        )
        let rightEdge = LatticeEdge(
            start: rightStringRange.lowerBound,
            end: rightStringRange.upperBound,
            surface: rightSurface,
            lemma: rightSurface
        )

        var updatedEdges = segmentationEdges
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
                                    surface: edgeLeftSurface,
                                    lemma: edgeLeftSurface
                                )
                            )
                            globallySplitEdges.append(
                                LatticeEdge(
                                    start: edgeRightStringRange.lowerBound,
                                    end: edgeRightStringRange.upperBound,
                                    surface: edgeRightSurface,
                                    lemma: edgeRightSurface
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

        applySegmentationEdges(updatedEdges, persistOverride: true)

        guard let selectedLeftEdgeIndex = updatedEdges.firstIndex(where: { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == leftRange.location && edge.surface == leftSurface
        }) else {
            return nil
        }

        selectedMergedEdgeBounds = selectedLeftEdgeIndex...selectedLeftEdgeIndex
        selectedSegmentLocation = leftRange.location
        selectedHighlightRangeOverride = leftRange

        let leftNeighborSurface = selectedLeftEdgeIndex > 0 ? updatedEdges[selectedLeftEdgeIndex - 1].surface : nil
        return (surface: leftSurface, leftNeighborSurface: leftNeighborSurface, rightNeighborSurface: rightSurface)
    }

    // Resolves the currently highlighted merged token range used by merge/split actions.
    func currentMergedSelectionNSRange() -> NSRange? {
        if let selectedHighlightRangeOverride,
           selectedHighlightRangeOverride.location != NSNotFound,
           selectedHighlightRangeOverride.length > 0 {
            return selectedHighlightRangeOverride
        }

        if let mergedBounds = selectedMergedEdgeBounds {
            let mergedStart = segmentationEdges[mergedBounds.lowerBound].start
            let mergedEnd = segmentationEdges[mergedBounds.upperBound].end
            let mergedNSRange = NSRange(mergedStart..<mergedEnd, in: text)
            if mergedNSRange.location != NSNotFound, mergedNSRange.length > 0 {
                return mergedNSRange
            }
        }

        guard let selectedSegmentLocation else {
            return nil
        }

        return segmentationRanges.compactMap { segmentRange in
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

    // Applies active segmentation edges to UI state and refreshes furigana using those exact token boundaries.
    func applySegmentationEdges(_ edges: [LatticeEdge], persistOverride: Bool) {
        segmentationEdges = edges
        segmentationRanges = edges.map { edge in
            edge.start..<edge.end
        }

        if persistOverride {
            let tokenRanges = buildTokenRanges(from: edges)
            self.tokenRanges = tokenRanges
            persistCurrentNoteIfNeeded()
        }

        scheduleFuriganaGeneration(for: text, edges: edges)
    }

    // Converts segmentation edges to explicit UTF-16 token ranges for note persistence.
    func buildTokenRanges(from edges: [LatticeEdge]) -> [TokenRange] {
        edges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else {
                return nil
            }

            return TokenRange(
                start: nsRange.location,
                end: nsRange.location + nsRange.length
            )
        }
    }

    // Rebuilds segmentation edges from persisted UTF-16 token ranges.
    func edgesFromTokenRanges(_ tokenRanges: [TokenRange], in sourceText: String) -> [LatticeEdge]? {
        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        var rebuiltEdges: [LatticeEdge] = []
        for tokenRange in tokenRanges {
            let startOffset = tokenRange.start
            let endOffset = tokenRange.end
            guard endOffset > startOffset else {
                continue
            }

            let startIndex = String.Index(utf16Offset: startOffset, in: sourceText)
            let endIndex = String.Index(utf16Offset: endOffset, in: sourceText)
            guard startIndex < endIndex else {
                continue
            }

            let surface = String(sourceText[startIndex..<endIndex])
            rebuiltEdges.append(
                LatticeEdge(
                    start: startIndex,
                    end: endIndex,
                    surface: surface,
                    lemma: surface
                )
            )
        }

        return rebuiltEdges.isEmpty ? nil : rebuiltEdges
    }

    // Normalizes persisted token ranges from a note so only valid ranges are applied.
    func normalizedTokenRanges(_ tokenRanges: [TokenRange]?, for sourceText: String) -> [TokenRange]? {
        guard let tokenRanges else {
            return nil
        }

        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        let normalizedRanges = tokenRanges
            .filter { tokenRange in
                tokenRange.start >= 0
                    && tokenRange.end > tokenRange.start
                    && tokenRange.end <= utf16TotalLength
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start {
                    return lhs.start < rhs.start
                }
                return lhs.end < rhs.end
            }

        guard normalizedRanges.isEmpty == false else {
            return nil
        }

        // Require exact contiguous coverage of the full text to keep range persistence deterministic.
        var cursor = 0
        for tokenRange in normalizedRanges {
            guard tokenRange.start == cursor else {
                return nil
            }
            cursor = tokenRange.end
        }

        guard cursor == utf16TotalLength else {
            return nil
        }

        return normalizedRanges
    }

    // Filters out non-lexical segments so punctuation and whitespace never trigger popovers.
    func shouldIgnoreSegmentForDefinitionLookup(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }

    // Validates whether two adjacent segments can be merged without crossing punctuation or newline boundaries.
    func isMergeAllowed(between leftEdge: LatticeEdge, and rightEdge: LatticeEdge) -> Bool {
        guard leftEdge.end == rightEdge.start else {
            return false
        }

        guard isLexicalSurface(leftEdge.surface), isLexicalSurface(rightEdge.surface) else {
            return false
        }

        let boundaryCharacterIndex = leftEdge.end
        if boundaryCharacterIndex > text.startIndex {
            let previousCharacter = text[text.index(before: boundaryCharacterIndex)]
            if previousCharacter == "\n" || previousCharacter == "\r" {
                return false
            }
        }

        if boundaryCharacterIndex < text.endIndex {
            let nextCharacter = text[boundaryCharacterIndex]
            if nextCharacter == "\n" || nextCharacter == "\r" {
                return false
            }
        }

        return true
    }

    // Determines whether a token surface includes lexical content rather than punctuation/whitespace only.
    func isLexicalSurface(_ surface: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return surface.unicodeScalars.contains { ignoredScalars.contains($0) == false }
    }

    // Flashes a temporary red boundary marker in read mode when an illegal merge is attempted.
    func flashIllegalMergeBoundary(between leftEdge: LatticeEdge, and rightEdge: LatticeEdge) {
        let boundaryRange = NSRange(leftEdge.start..<rightEdge.start, in: text)
        guard boundaryRange.location != NSNotFound else {
            return
        }

        illegalMergeBoundaryLocation = boundaryRange.location
        illegalMergeFlashTask?.cancel()
        illegalMergeFlashTask = Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard Task.isCancelled == false else {
                return
            }

            await MainActor.run {
                illegalMergeBoundaryLocation = nil
            }
        }
    }

}
