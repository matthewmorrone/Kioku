import SwiftUI
import UIKit

// Hosts segmentation and segment action helpers for the read screen.
extension ReadView {
    // Applies a user-chosen reading override for the currently selected segment and persists it across furigana recomputation.
    func applyReadingOverride(reading: String) {
        guard let location = selectedSegmentLocation else { return }

        // Derive the surface text length from the merged edge bounds so the furigana rect covers
        // the correct source characters, not the reading's kana length.
        let surfaceLength: Int
        if let bounds = selectedMergedEdgeBounds,
           bounds.lowerBound < segmentEdges.count,
           bounds.upperBound < segmentEdges.count {
            let start = segmentEdges[bounds.lowerBound].start
            let end = segmentEdges[bounds.upperBound].end
            surfaceLength = NSRange(start..<end, in: text).length
        } else {
            // Fall back to the existing computed length for this location.
            surfaceLength = furiganaLengthBySegmentLocation[location] ?? 0
        }
        guard surfaceLength > 0 else { return }

        // Remove all existing per-kanji-run furigana within the segment range so the single
        // override entry is the only annotation shown for this segment.
        let segmentNSRange = NSRange(location: location, length: surfaceLength)
        let priorLengths = furiganaLengthBySegmentLocation
        let staleLocations = Set(furiganaBySegmentLocation.keys.filter { loc in
            let len = priorLengths[loc] ?? 0
            return NSIntersectionRange(NSRange(location: loc, length: len), segmentNSRange).length > 0
        })
        furiganaBySegmentLocation = furiganaBySegmentLocation.filter { !staleLocations.contains($0.key) }
        furiganaLengthBySegmentLocation = furiganaLengthBySegmentLocation.filter { !staleLocations.contains($0.key) }

        selectedReadingOverrideByLocation[location] = reading
        furiganaBySegmentLocation[location] = reading
        furiganaLengthBySegmentLocation[location] = surfaceLength
    }

    // Clears note-backed segment range overrides and restores computed segmentation from the segmenter.
    func resetSegmentationToComputed() {
        segments = nil
        selectedReadingOverrideByLocation = [:]
        illegalMergeBoundaryLocation = nil
        illegalMergeFlashTask?.cancel()
        selectedSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedMergedEdgeBounds = nil
        SegmentDefinitionPopoverPresenter.shared.dismissPopover()

        if readResourcesReady && isEditMode == false {
            refreshSegmentationRanges()
        } else {
            segmentLatticeEdges = []
            segmentEdges = []
            segmentRanges = []
            unknownSegmentLocations = []
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
        }

        persistCurrentNoteIfNeeded()
    }

    // Rebuilds greedy segmentation ranges used by alternating segment colors in the editor.
    func refreshSegmentationRanges() {
        guard readResourcesReady else {
            illegalMergeBoundaryLocation = nil
            illegalMergeFlashTask?.cancel()
            furiganaComputationTask?.cancel()
            segmentLatticeEdges = []
            segmentEdges = []
            segmentRanges = []
            unknownSegmentLocations = []
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedMergedEdgeBounds = nil
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            return
        }

        let segmentationResult = segmenter.longestMatchResult(for: text)
        segmentLatticeEdges = segmentationResult.latticeEdges
        // segmenter.debugPrintLattice(for: text)
        let baseEdges = segmentationResult.selectedEdges
        let refreshedEdges: [LatticeEdge]
        if let segments,
           let overriddenEdges = edgesFromSegmentRanges(segments, in: text) {
            if shouldDiscardPersistedSegmentOverride(overriddenEdges: overriddenEdges, computedEdges: baseEdges) {
                self.segments = nil
                persistCurrentNoteIfNeeded()
                refreshedEdges = baseEdges
            } else {
                refreshedEdges = overriddenEdges
            }
        } else {
            if segments != nil {
                segments = nil
                persistCurrentNoteIfNeeded()
            }
            refreshedEdges = baseEdges
        }

        segmentEdges = refreshedEdges
        segmentRanges = refreshedEdges.map { edge in
            edge.start..<edge.end
        }
        unknownSegmentLocations = unknownSegmentLocations(for: refreshedEdges)
        recordRuntimeSegmentationSnapshot(for: refreshedEdges)

        // Clears stale selection if the tapped segment no longer exists after recomputing ranges.
        if let selectedSegmentLocation {
            let hasSelectedSegment = segmentRanges.contains { segmentRange in
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

    // Records the current runtime segmentation for the active note so export can reuse live segment boundaries.
    func recordRuntimeSegmentationSnapshot(for edges: [LatticeEdge]) {
        guard let activeNoteID else {
            return
        }

        let segments = buildSegmentRanges(from: edges)
        notesStore.recordRuntimeSegmentation(
            noteID: activeNoteID,
            content: text,
            segments: segments
        )
    }

    // Drops persisted segment overrides only when they are fully redundant with the current computed segmentation.
    func shouldDiscardPersistedSegmentOverride(overriddenEdges: [LatticeEdge], computedEdges: [LatticeEdge]) -> Bool {
        let computedSegmentRanges = buildSegmentRanges(from: computedEdges)
        let overriddenSegmentRanges = buildSegmentRanges(from: overriddenEdges)
        return overriddenSegmentRanges == computedSegmentRanges
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
        // debugPrintLatticeSectionForCurrentSelection(at: tappedSegmentLocation)

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
                onSelectPrevious: {
                    isSheetSwipeTransitionActive = true
                    let outcome = moveSelectedSegmentSelection(isMovingForward: false)
                    if let sourceView,
                       let selectedSegmentLocation,
                       let selectedSegmentRect = selectedSegmentRectInTextView(sourceView: sourceView, selectedLocation: selectedSegmentLocation) {
                        preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: selectedSegmentRect, animated: false)
                    }

                    Task { @MainActor in
                        await Task.yield()
                        isSheetSwipeTransitionActive = false
                        scheduleFuriganaGeneration(for: text, edges: segmentEdges)
                    }

                    return outcome
                },
                onSelectNext: {
                    isSheetSwipeTransitionActive = true
                    let outcome = moveSelectedSegmentSelection(isMovingForward: true)
                    if let sourceView,
                       let selectedSegmentLocation,
                       let selectedSegmentRect = selectedSegmentRectInTextView(sourceView: sourceView, selectedLocation: selectedSegmentLocation) {
                        preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: selectedSegmentRect, animated: false)
                    }

                    Task { @MainActor in
                        await Task.yield()
                        isSheetSwipeTransitionActive = false
                        scheduleFuriganaGeneration(for: text, edges: segmentEdges)
                    }

                    return outcome
                },
                onMergeLeft: {
                    mergeAdjacentSegment(isMergingLeft: true)
                },
                onMergeRight: {
                    mergeAdjacentSegment(isMergingLeft: false)
                },
                onSplitApply: { splitOffset in
                    applySplitSelection(offsetUTF16: splitOffset)
                },
                sheetReadingsProvider: {
                    uniqueReadingsForCurrentSelectedKanjiSegment()
                },
                sheetSublatticeProvider: {
                    sublatticeEdgesForCurrentSelectedSegment()
                },
                segmentRangeProvider: {
                    currentMergedSelectionNSRange()
                },
                sheetLexiconDebugProvider: {
                    lexiconDebugInfoForCurrentSelectedSegment()
                },
                onReadingSelected: { reading in
                    applyReadingOverride(reading: reading)
                },
                onDismiss: {
                    isSheetSwipeTransitionActive = false
                    clearSelectedSegmentStateAfterPopoverDismissal()
                    restoreScrollAfterSheetDismissal(sourceView: sourceView, animated: false)
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

    // Resolves the tapped segment surface and the best-ordered gloss from dictionary results.
    func definitionPayloadForSelectedSegment(at selectedLocation: Int) -> (surface: String, definition: String)? {
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

        let matchingEdge = segmentEdges.first { edge in
            let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
            return edgeNSRange.location == selectedLocation && edgeNSRange.length > 0
        }

        let lookupCandidates = orderedLookupCandidates(surface: tappedSurface, lemma: segmenter.preferredLemma(for: tappedSurface))
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
        var seenCandidates = Set<String>()

        // Adds a lookup candidate in order while preventing duplicate retries.
        func appendCandidate(_ candidate: String) {
            guard seenCandidates.contains(candidate) == false else {
                return
            }

            seenCandidates.insert(candidate)
            candidates.append(candidate)
        }

        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSurface.isEmpty == false {
            appendCandidate(trimmedSurface)
            let expandedSurfaceCandidates = ScriptClassifier.iterationExpandedCandidates(for: trimmedSurface).sorted()
            for expandedSurface in expandedSurfaceCandidates where expandedSurface != trimmedSurface {
                appendCandidate(expandedSurface)
            }
        }

        if let lemma {
            let trimmedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLemma.isEmpty == false && trimmedLemma != trimmedSurface {
                appendCandidate(trimmedLemma)
                let expandedLemmaCandidates = ScriptClassifier.iterationExpandedCandidates(for: trimmedLemma).sorted()
                for expandedLemma in expandedLemmaCandidates where expandedLemma != trimmedLemma {
                    appendCandidate(expandedLemma)
                }
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

                    candidateGlosses.append((
                        gloss: trimmedGloss,
                        entryIndex: entryIndex,
                        senseIndex: senseIndex,
                        glossIndex: glossIndex
                    ))
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
        let activeBounds = selectedMergedEdgeBounds ?? initialMergedEdgeBounds(for: selectedLocation)
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

        selectedMergedEdgeBounds = selectedLeftEdgeIndex...selectedLeftEdgeIndex
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

        if let mergedBounds = selectedMergedEdgeBounds {
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

    // Applies active segmentation edges to UI state and refreshes furigana using those exact segment boundaries.
    func applySegmentEdges(_ edges: [LatticeEdge], persistOverride: Bool) {
        segmentEdges = edges
        segmentRanges = edges.map { edge in
            edge.start..<edge.end
        }
        unknownSegmentLocations = unknownSegmentLocations(for: edges)
        recordRuntimeSegmentationSnapshot(for: edges)

        if persistOverride {
            let segments = buildSegmentRanges(from: edges)
            self.segments = segments
            persistCurrentNoteIfNeeded()
        }

        scheduleFuriganaGeneration(for: text, edges: edges)
    }

    // Marks the UTF-16 start locations of segments that do not resolve through the dictionary pipeline.
    func unknownSegmentLocations(for edges: [LatticeEdge]) -> Set<Int> {
        var unknownLocations: Set<Int> = []

        for edge in edges {
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else {
                continue
            }

            if segmenter.resolvesSurface(edge.surface) == false {
                unknownLocations.insert(nsRange.location)
            }
        }

        return unknownLocations
    }

    // Converts segment edges to explicit UTF-16 segment ranges for note persistence.
    func buildSegmentRanges(from edges: [LatticeEdge]) -> [SegmentRange] {
        edges.compactMap { edge in
            let nsRange = NSRange(edge.start..<edge.end, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else {
                return nil
            }

            return SegmentRange(
                start: nsRange.location,
                end: nsRange.location + nsRange.length
            )
        }
    }

    // Rebuilds segmentation edges from persisted UTF-16 segment ranges.
    func edgesFromSegmentRanges(_ segments: [SegmentRange], in sourceText: String) -> [LatticeEdge]? {
        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        var rebuiltEdges: [LatticeEdge] = []
        for segmentRange in segments {
            let startOffset = segmentRange.start
            let endOffset = segmentRange.end
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
                    surface: surface
                )
            )
        }

        return rebuiltEdges.isEmpty ? nil : rebuiltEdges
    }

    // Normalizes persisted segment ranges from a note so only valid ranges are applied.
    func normalizedSegmentRanges(_ segments: [SegmentRange]?, for sourceText: String) -> [SegmentRange]? {
        guard let segments else {
            return nil
        }

        let utf16TotalLength = sourceText.utf16.count
        guard utf16TotalLength > 0 else {
            return nil
        }

        let normalizedRanges = segments
            .filter { segmentRange in
                segmentRange.start >= 0
                    && segmentRange.end > segmentRange.start
                    && segmentRange.end <= utf16TotalLength
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
        for segmentRange in normalizedRanges {
            guard segmentRange.start == cursor else {
                return nil
            }
            cursor = segmentRange.end
        }

        guard cursor == utf16TotalLength else {
            return nil
        }

        return normalizedRanges
    }

}
