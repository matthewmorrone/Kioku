import SwiftUI
import UIKit

// Hosts reading override, refresh, tap handling, and definition lookup for the read screen.
// Merge/split operations live in ReadView+MergeSplit.swift.
// Segment building utilities live in ReadView+SegmentBuilding.swift.
extension ReadView {
    // Applies a user-chosen reading override for the currently selected segment and persists it across furigana recomputation.
    // When shouldApplyChangesGlobally is active, the override is also applied to all other segment edges with the same surface.
    func applyReadingOverride(reading: String) {
        guard let location = selectedSegmentLocation else { return }

        // Derive the surface text and length from the merged edge bounds so the furigana rect covers
        // the correct source characters, not the reading's kana length.
        let surfaceLength: Int
        let selectedSurface: String?
        if let bounds = selectedBounds,
           bounds.lowerBound < segmentEdges.count,
           bounds.upperBound < segmentEdges.count {
            let start = segmentEdges[bounds.lowerBound].start
            let end = segmentEdges[bounds.upperBound].end
            surfaceLength = NSRange(start..<end, in: text).length
            selectedSurface = surfaceLength > 0 ? String(text[start..<end]) : nil
        } else {
            // Fall back to the existing computed length for this location.
            surfaceLength = furiganaLengthBySegmentLocation[location] ?? 0
            if surfaceLength > 0, let range = Range(NSRange(location: location, length: surfaceLength), in: text) {
                selectedSurface = String(text[range])
            } else {
                selectedSurface = nil
            }
        }
        guard surfaceLength > 0 else { return }

        // Build target list: always include the current selection; when applying globally, add all
        // other edges that share the same surface text so the override is consistent across the note.
        var targets: [(location: Int, length: Int)] = [(location, surfaceLength)]
        if shouldApplyChangesGlobally, let surface = selectedSurface {
            for edge in segmentEdges {
                let edgeNSRange = NSRange(edge.start..<edge.end, in: text)
                guard edgeNSRange.location != NSNotFound,
                      edgeNSRange.length > 0,
                      edgeNSRange.location != location,
                      edge.surface == surface else { continue }
                targets.append((edgeNSRange.location, edgeNSRange.length))
            }
        }

        // Apply the override to each target, removing stale per-kanji-run furigana within the range
        // so the single override entry is the only annotation shown for each matching segment.
        for (targetLocation, targetLength) in targets {
            let segmentNSRange = NSRange(location: targetLocation, length: targetLength)
            let staleLocations = Set(furiganaBySegmentLocation.keys.filter { loc in
                let len = furiganaLengthBySegmentLocation[loc] ?? 0
                return NSIntersectionRange(NSRange(location: loc, length: len), segmentNSRange).length > 0
            })
            furiganaBySegmentLocation = furiganaBySegmentLocation.filter { !staleLocations.contains($0.key) }
            furiganaLengthBySegmentLocation = furiganaLengthBySegmentLocation.filter { !staleLocations.contains($0.key) }
            furiganaBySegmentLocation[targetLocation] = reading
            furiganaLengthBySegmentLocation[targetLocation] = targetLength
        }
        // Rebuild segments with updated furigana then persist.
        segments = buildSegmentRanges(
            from: segmentEdges,
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation
        )
        persistCurrentNoteIfNeeded()
    }

    // Removes the persisted reading for the currently selected segment and re-runs furigana computation.
    func clearReadingOverrideForCurrentSegment() {
        guard let location = selectedSegmentLocation else { return }
        furiganaBySegmentLocation.removeValue(forKey: location)
        furiganaLengthBySegmentLocation.removeValue(forKey: location)
        // scheduleFuriganaGeneration will rebuild segments and persist once it completes.
        scheduleFuriganaGeneration(for: text, edges: segmentEdges)
    }

    // Clears note-backed segment range overrides and restores computed segmentation from the segmenter.
    func resetSegmentationToComputed() {
        segments = nil
        illegalMergeBoundaryLocation = nil
        illegalMergeFlashTask?.cancel()
        selectedSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedBounds = nil
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        pendingLLMChangesByLocation = [:]
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false
        SegmentLookupSheet.shared.dismissPopover()

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
    // Skips recomputation when persisted segments already cover the text — trusts them as ground truth.
    func refreshSegmentationRanges() {
        if let segments, let edges = edgesFromSegmentRanges(segments, in: text) {
            segmentEdges = edges
            segmentRanges = edges.map { $0.start..<$0.end }
            unknownSegmentLocations = []
            recordRuntimeSegmentationSnapshot(for: edges)
            scheduleFuriganaGeneration(for: text, edges: edges)
            return
        }

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
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            return
        }

        StartupTimer.mark("refreshSegmentationRanges: running segmenter")
        let segmentationResult = StartupTimer.measure("segmenter.longestMatchResult") {
            segmenter.longestMatchResult(for: text)
        }
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
                selectedBounds = nil
                SegmentLookupSheet.shared.dismissPopover()
            }
        }

        scheduleFuriganaGeneration(for: text, edges: refreshedEdges)
    }

    // Records the current runtime segmentation for the active note so export can reuse live segment boundaries.
    func recordRuntimeSegmentationSnapshot(for edges: [LatticeEdge]) {
        guard let activeNoteID else {
            return
        }

        let segments = buildSegmentRanges(
            from: edges,
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation
        )
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
        // If the tapped segment has a pending LLM change, show what changed instead of the lookup sheet.
        if let tappedSegmentLocation,
           let changeDescription = pendingLLMChangesByLocation[tappedSegmentLocation] {
            llmChangePopoverText = changeDescription
            llmChangePopoverLocation = tappedSegmentLocation
            isShowingLLMChangePopover = true
            return
        }

        guard let tappedSegmentLocation else {
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        if selectedSegmentLocation == tappedSegmentLocation {
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        selectedSegmentLocation = tappedSegmentLocation
        selectedHighlightRangeOverride = nil
        selectedBounds = initialMergedEdgeBounds(for: tappedSegmentLocation)
        // debugPrintLatticeSectionForCurrentSelection(at: tappedSegmentLocation)

        let adjacentSurfaces = adjacentSegmentSurfaces(for: tappedSegmentLocation)

        if prefersSheetDirectSegmentActions {
            guard let segmentSurface = surfaceForSegment(at: tappedSegmentLocation) else {
                SegmentLookupSheet.shared.dismissPopover()
                return
            }

            recordLookupHistory(surface: segmentSurface)

            preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: tappedSegmentRect)
            SegmentLookupSheet.shared.presentSheet(
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
                sheetFrequencyProvider: {
                    frequencyRankForCurrentSelectedSegment()
                },
                sheetLemmaInfoProvider: {
                    lemmaInfoForCurrentSelectedSegment()
                },
                onReadingSelected: { reading in
                    applyReadingOverride(reading: reading)
                },
                onReadingReset: {
                    clearReadingOverrideForCurrentSegment()
                },
                activeReadingOverrideProvider: {
                    guard let location = selectedSegmentLocation,
                          let edge = segmentEdges.first(where: {
                              NSRange($0.start..<$0.end, in: text).location == location
                          }) else { return nil }
                    let reading = reconstructedReading(for: edge.surface, at: location)
                    return reading.isEmpty ? nil : reading
                },
                pathSegmentFrequencyProvider: { surface in
                    if let data = surfaceReadingData[surface]?.frequencyByReading { return data }
                    // Inflected surfaces won't appear in the frequency map; fall back through lemmas.
                    guard let lexicon else { return nil }
                    for lemma in lexicon.lemma(surface: surface) {
                        if let data = surfaceReadingData[lemma]?.frequencyByReading { return data }
                    }
                    return nil
                },
                sheetDictionaryEntryProvider: {
                    // Use the lemma form when the surface is inflected so we fetch the base dictionary entry once.
                    guard let surface = currentSelectedSurface(),
                          let store = dictionaryStore else { return nil }
                    let lookupSurface = lemmaInfoForCurrentSelectedSegment()?.lemma ?? surface
                    return (try? store.lookup(surface: lookupSurface, mode: .kanjiAndKana))?.first
                },
                sheetIsSavedProvider: {
                    guard let entry = SegmentLookupSheet.shared.currentSheetDictionaryEntry else { return false }
                    return wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
                },
                sheetSaveToggle: {
                    guard let surface = currentSelectedSurface(),
                          let entry = SegmentLookupSheet.shared.currentSheetDictionaryEntry else { return }
                    // Save with the tapped surface so WordDetailView can still show the encountered form.
                    if wordsStore.words.contains(where: { $0.canonicalEntryID == entry.entryId }) {
                        wordsStore.remove(id: entry.entryId)
                    } else {
                        wordsStore.add(SavedWord(canonicalEntryID: entry.entryId, surface: surface))
                    }
                },
                sheetOpenWordDetail: {
                    guard let surface = currentSelectedSurface(),
                          let entry = SegmentLookupSheet.shared.currentSheetDictionaryEntry else { return }
                    // Ensure the word exists in the saved list before routing to the shared Words tab detail flow.
                    if wordsStore.words.contains(where: { $0.canonicalEntryID == entry.entryId }) == false {
                        wordsStore.add(SavedWord(canonicalEntryID: entry.entryId, surface: surface))
                    }
                    wotdNavigation.pendingEntryID = entry.entryId
                },
                sheetWordComponentsProvider: {
                    guard let surface = currentSelectedSurface() else { return nil }
                    let edges = segmenter.longestMatchEdges(for: surface)
                    guard edges.count > 1 else { return nil }
                    return edges.compactMap { edge -> (String, String?)? in
                        let entries = try? dictionaryStore?.lookup(surface: edge.surface, mode: .kanjiAndKana)
                        let gloss = entries?.first?.senses.first?.glosses.first
                        return (edge.surface, gloss)
                    }
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
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        guard let sourceView, let tappedSegmentRect else {
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        SegmentLookupSheet.shared.presentPopover(
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
}
