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
        transientBlankReadingSegmentLocation = nil

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

        // Apply the override to each target, removing stale furigana inside the range first.
        // Overrides use the same per-kanji-run projection as the lookup-sheet title so okurigana
        // never ends up inside the highlighted word's furigana.
        for (targetLocation, targetLength) in targets {
            let segmentNSRange = NSRange(location: targetLocation, length: targetLength)
            let staleLocations = Set(furiganaBySegmentLocation.keys.filter { loc in
                let len = furiganaLengthBySegmentLocation[loc] ?? 0
                return NSIntersectionRange(NSRange(location: loc, length: len), segmentNSRange).length > 0
            })
            furiganaBySegmentLocation = furiganaBySegmentLocation.filter { !staleLocations.contains($0.key) }
            furiganaLengthBySegmentLocation = furiganaLengthBySegmentLocation.filter { !staleLocations.contains($0.key) }

            let chars = Array(selectedSurface ?? "")
            let runs = FuriganaAttributedString.kanjiRuns(in: selectedSurface ?? "")

            if let selectedSurface, runs.isEmpty == false,
               let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: selectedSurface, reading: reading, runs: runs),
               runReadings.count == runs.count {
                for (index, run) in runs.enumerated() {
                    let runSurface = String(chars[run.start..<run.end])
                    let runReading = runReadings[index]
                    guard runReading.isEmpty == false, runReading != runSurface else {
                        continue
                    }

                    let prefixUTF16 = String(chars[..<run.start]).utf16.count
                    let runLength = String(chars[run.start..<run.end]).utf16.count
                    let runLocation = targetLocation + prefixUTF16
                    furiganaBySegmentLocation[runLocation] = runReading
                    furiganaLengthBySegmentLocation[runLocation] = runLength
                }
            }
        }
        // Rebuild segments with updated furigana then persist.
        segments = buildSegmentRanges(
            from: segmentEdges,
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation
        )
        persistCurrentNoteIfNeeded()
    }

    // Removes the persisted reading for the currently selected segment and re-runs furigana
    // computation so the auto-derived default refills the gap. The transient blanking flag
    // is also set so the UI shows no ruby until the recompute finishes — without that, the
    // user's old override would briefly remain visible during the async backfill.
    func clearReadingOverrideForCurrentSegment() {
        guard let location = selectedSegmentLocation else { return }
        transientBlankReadingSegmentLocation = location
        furiganaBySegmentLocation.removeValue(forKey: location)
        furiganaLengthBySegmentLocation.removeValue(forKey: location)
        // performScheduleFuriganaGeneration uses backfill semantics — it only writes a
        // location if the current map has no entry there. Removing the entry first means
        // the freshly computed default reading is the value that gets backfilled.
        scheduleFuriganaGeneration(for: text, edges: segmentEdges)
    }

    // Clears note-backed segment range overrides AND user-edited furigana readings,
    // then restores computed segmentation from the segmenter. The furigana clear is
    // done unconditionally so the reset button visibly drops manual reading edits
    // (otherwise the post-segmenter backfill leaves stale overrides in place).
    func resetSegmentationToComputed() {
        segments = nil
        illegalMergeBoundaryLocation = nil
        illegalMergeFlashTask?.cancel()
        selectedSegmentLocation = nil
        transientBlankReadingSegmentLocation = nil
        selectedHighlightRangeOverride = nil
        selectedBounds = nil
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        pendingLLMChangesByLocation = [:]
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false
        // Always drop user-edited readings so the reset is total. Re-segmentation will
        // backfill defaults from the lexicon below.
        furiganaBySegmentLocation = [:]
        furiganaLengthBySegmentLocation = [:]
        SegmentLookupSheet.shared.dismissPopover()

        if readResourcesReady && isEditMode == false {
            refreshSegmentationRanges()
        } else {
            segmentLatticeEdges = []
            segmentEdges = []
            segmentRanges = []
            unknownSegmentLocations = []
        }

        // Belt-and-braces persistence clear so a buggy furigana entry that's already on disk
        // (or sitting in the in-memory runtime snapshot the store uses for export) can't sneak
        // back into the view via load/export paths.
        //   1. Drop the runtime snapshot for this note — exportSegmentRanges reads this first
        //      and would otherwise serve the OLD furigana-embedded segments back.
        //   2. Persist with segments=nil so the on-disk note has no embedded furigana either;
        //      on next note open the load path sees segments=nil and re-runs the segmenter
        //      against the current (fixed) furigana pipeline rather than restoring stale data.
        //   3. Synchronously flush so the disk state matches before any async path runs.
        if let activeNoteID {
            notesStore.clearRuntimeSegmentation(noteID: activeNoteID)
        }
        persistCurrentNoteIfNeeded()
        notesStore.flushPendingSave()
    }

    // Public entry point. Two paths:
    //   - Fast path: persisted segments validate against current text → restore edges
    //     synchronously, NO prompt. This is restoration, not automatic segmentation.
    //   - Slow path: actually run the segmenter → queue a confirm prompt.
    // Empty text is a no-op in either path.
    func refreshSegmentationRanges(reason: String = #function) {
        guard text.isEmpty == false else { return }

        if let segments, let edges = edgesFromSegmentRanges(segments, in: text) {
            segmentEdges = edges
            segmentRanges = edges.map { $0.start..<$0.end }
            unknownSegmentLocations = []
            recordRuntimeSegmentationSnapshot(for: edges)
            return
        }

        requestAutoSegConfirm(
            reason: "refreshSegmentationRanges ← \(reason)",
            action: .refreshSegmentationRanges
        )
    }

    // Rebuilds greedy segmentation ranges used by alternating segment colors in the editor.
    // Skips recomputation when persisted segments already cover the text — trusts them as ground truth.
    func performRefreshSegmentationRanges() {
        segmentationRefreshTask?.cancel()
        segmentationRefreshTask = nil

        if let segments, let edges = edgesFromSegmentRanges(segments, in: text) {
            segmentEdges = edges
            segmentRanges = edges.map { $0.start..<$0.end }
            unknownSegmentLocations = []
            recordRuntimeSegmentationSnapshot(for: edges)
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
            transientBlankReadingSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            return
        }

        let sourceText = text
        let sourceNoteID = activeNoteID
        let persistedSegments = segments

        StartupTimer.mark("refreshSegmentationRanges: running segmenter")
        segmentationRefreshTask = Task(priority: .userInitiated) {
            let segmentationResult = await Task.detached(priority: .userInitiated) { [segmenter = self.segmenter, sourceText] in
                StartupTimer.measure("segmenter.longestMatchResult") {
                    segmenter.longestMatchResult(for: sourceText)
                }
            }
            .value

            guard Task.isCancelled == false else {
                return
            }

            await MainActor.run {
                guard
                    Task.isCancelled == false,
                    text == sourceText,
                    activeNoteID == sourceNoteID,
                    segments == persistedSegments,
                    isEditMode == false
                else {
                    return
                }

                segmentLatticeEdges = segmentationResult.latticeEdges
                // segmenter.debugPrintLattice(for: text)
                let baseEdges = segmentationResult.selectedEdges
                let refreshedEdges: [LatticeEdge]
                if let persistedSegments,
                   let overriddenEdges = edgesFromSegmentRanges(persistedSegments, in: sourceText) {
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
                        let nsRange = NSRange(segmentRange, in: sourceText)
                        return nsRange.location == selectedSegmentLocation && nsRange.length > 0
                    }
                    if hasSelectedSegment == false {
                        self.selectedSegmentLocation = nil
                        selectedHighlightRangeOverride = nil
                        selectedBounds = nil
                        SegmentLookupSheet.shared.dismissPopover()
                    }
                }

                segmentationRefreshTask = nil
                // Direct call (not via the queueing public entry point) so the user only sees
                // one confirm for the seg+furigana pair when refreshSegmentationRanges runs —
                // furigana is a downstream of the segmentation refresh that just got approved.
                // Skip entirely when no kanji edges exist; there's nothing to generate.
                let hasKanjiEdges = refreshedEdges.contains { ScriptClassifier.containsKanji($0.surface) }
                if hasKanjiEdges {
                    performScheduleFuriganaGeneration(for: sourceText, edges: refreshedEdges)
                }
            }
        }
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
    func handleReadModeSegmentTap(_ tappedSegmentLocation: Int?, tappedSegmentRect: CGRect?, sourceView: UIScrollView?) {
        TapDiagnostics.mark("handleReadModeSegmentTap entered")
        defer { TapDiagnostics.mark("handleReadModeSegmentTap returning") }
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

            // Drilling into a compound component row spawns a stacked, full-chrome lookup sheet
            // for the tapped lemma. Installed here so the closure captures the current ReadView
            // value (its dictionaryStore/lexicon/wordsStore references are already there).
            SegmentLookupSheet.shared.onCompoundComponentTapped = { lemma, gloss in
                presentNestedLemmaLookup(lemma: lemma, gloss: gloss)
            }

            TapDiagnostics.mark("about to preScroll")
            preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: tappedSegmentRect)
            TapDiagnostics.mark("preScroll returned, about to presentSheet")
            SegmentLookupSheet.shared.presentSheet(
                surface: segmentSurface,
                leftNeighborSurface: adjacentSurfaces.left,
                rightNeighborSurface: adjacentSurfaces.right,
                onSelectPrevious: {
                    isSheetSwipeTransitionActive = true
                    let outcome = moveSelectedSegmentSelection(isMovingForward: false)
                    if let textView = sourceView as? UITextView,
                       let selectedSegmentLocation,
                       let selectedSegmentRect = selectedSegmentRectInTextView(sourceView: textView, selectedLocation: selectedSegmentLocation) {
                        preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: selectedSegmentRect) {
                            Task { @MainActor in
                                await Task.yield()
                                isSheetSwipeTransitionActive = false
                            }
                        }
                    } else {
                        Task { @MainActor in
                            await Task.yield()
                            isSheetSwipeTransitionActive = false
                        }
                    }

                    return outcome
                },
                onSelectNext: {
                    isSheetSwipeTransitionActive = true
                    let outcome = moveSelectedSegmentSelection(isMovingForward: true)
                    if let textView = sourceView as? UITextView,
                       let selectedSegmentLocation,
                       let selectedSegmentRect = selectedSegmentRectInTextView(sourceView: textView, selectedLocation: selectedSegmentLocation) {
                        preScrollSegmentForSheetVisibility(sourceView: sourceView, tappedSegmentRect: selectedSegmentRect) {
                            Task { @MainActor in
                                await Task.yield()
                                isSheetSwipeTransitionActive = false
                            }
                        }
                    } else {
                        Task { @MainActor in
                            await Task.yield()
                            isSheetSwipeTransitionActive = false
                        }
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
                // Readings come from the in-memory `surfaceReadingData` map (built once at
                // startup, no SQL). Inflected forms fall back through every admitted
                // deinflection candidate, not just the segmenter's single preferred lemma —
                // this is what lets 触れられない expose both ふ (from 触れる) and さわ (from 触る)
                // through the arrow controls. Crucially, lemma readings are projected
                // FORWARD through the inflection chain to surface readings (さわる → さわれられない,
                // ふれる → ふれられない) so the header renderer can align them against the inflected
                // surface and crop to per-kanji ruby — bare lemma readings can't align because
                // their length is shorter than the okurigana tail of the surface.
                sheetReadingsProvider: {
                    let surface = currentSelectedSurface() ?? ""
                    if let data = surfaceReadingData[surface], data.readings.isEmpty == false {
                        return data.readings
                    }
                    guard let lexicon else {
                        if let lemma = segmenter.preferredLemma(for: surface),
                           let lemmaData = surfaceReadingData[lemma] {
                            return lemmaData.readings
                        }
                        return []
                    }
                    var combinedReadings: [String] = []
                    var seenReadings: Set<String> = []
                    for group in lexicon.surfaceReadingsByLemma(surface: surface) {
                        for reading in group.surfaceReadings where seenReadings.insert(reading).inserted {
                            combinedReadings.append(reading)
                        }
                    }
                    return combinedReadings
                },
                // Sublattice is from pre-computed in-memory lattice edges — fast.
                sheetSublatticeProvider: {
                    sublatticeEdgesForCurrentSelectedSegment()
                },
                segmentRangeProvider: {
                    currentMergedSelectionNSRange()
                },
                sheetLexiconDebugProvider: { "" },
                // Frequency is keyed by surface in the pre-built in-memory map. Skip the
                // Lexicon-based lemma fallback (deinflection) — Breakdown handles that.
                sheetFrequencyProvider: {
                    guard let surface = currentSelectedSurface() else { return nil }
                    return surfaceReadingData[surface]?.frequencyByReading
                },
                // Lemma info uses Lexicon.inflectionInfo which is now SQL-free thanks to
                // the in-memory surface→POS-bits map. Restored from the deferred state.
                sheetLemmaInfoProvider: {
                    lemmaInfoForCurrentSelectedSegment()
                },
                // Per-reading lemma map: lets the arrow controls cycle the lemma + gloss along
                // with the reading. For 触れられない we admit both 触れる (depth 2) and 触る (depth 3);
                // each contributes a surface-projected reading (ふれられない / さわれられない) and its
                // dictionary entry, so arrowing between the projected readings also flips the
                // lemma label and gloss panel. The projected reading is what currentReadings
                // actually cycles through (see sheetReadingsProvider), so this map keys on the
                // same string. Surfaces whose own surfaceReadingData has direct entries (i.e.
                // dictionary surfaces, not inflected) get no map — the existing single-lemma
                // path handles them.
                sheetLemmaInfoByReadingProvider: {
                    let surface = currentSelectedSurface() ?? ""
                    guard surface.isEmpty == false, let lexicon, let store = dictionaryStore else { return [:] }
                    if let data = surfaceReadingData[surface], data.readings.isEmpty == false {
                        return [:]
                    }
                    var byReading: [String: (lemma: String, chain: [String], entry: DictionaryEntry?)] = [:]
                    for group in lexicon.surfaceReadingsByLemma(surface: surface) {
                        let lemmaMode: LookupMode = ScriptClassifier.containsKanji(group.lemma) ? .kanjiAndKana : .kanaOnly
                        let entry = (try? store.lookup(surface: group.lemma, mode: lemmaMode))?.first
                        for reading in group.surfaceReadings where byReading[reading] == nil {
                            byReading[reading] = (lemma: group.lemma, chain: group.chain, entry: entry)
                        }
                    }
                    return byReading
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
                    if transientBlankReadingSegmentLocation == location {
                        return nil
                    }
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
                    resolvedDictionaryEntryForCurrentSelectedSegment()
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
                        let sourceIDs = activeNoteID.map { [$0] } ?? []
                        let senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
                        wordsStore.add(SavedWord(canonicalEntryID: entry.entryId, surface: surface, sourceNoteIDs: sourceIDs, selectedSenseIDs: senseIDs))
                    }
                },
                sheetOpenWordDetail: {
                    guard let surface = currentSelectedSurface(),
                          let entry = resolvedDictionaryEntryForCurrentSelectedSegment() else { return }
                    let reading = SegmentLookupSheet.shared.currentSheetUniqueReadings.first
                    let paths = LatticeEdge.validPaths(from: SegmentLookupSheet.shared.currentSheetSublatticeEdges)
                    onOpenWordDetail?(entry.entryId, surface, reading, paths)
                },
                // Deferred to Breakdown expansion (see sheetReadingsProvider comment).
                sheetWordComponentsProvider: { nil },
                sheetCompoundComponentsProvider: { nil },
                onWillDismiss: { completion in
                    restoreScrollAfterSheetDismissal(sourceView: sourceView, completion: completion)
                },
                onDismiss: {
                    isSheetSwipeTransitionActive = false
                    clearSelectedSegmentStateAfterPopoverDismissal()
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

    // Resolves ordered lookup candidates for the current selected segment by surface first, then lemma fallback.
    private func currentSelectedLookupCandidates() -> [String] {
        guard let surface = currentSelectedSurface() else { return [] }
        return orderedLookupCandidates(
            surface: surface,
            lemma: lemmaInfoForCurrentSelectedSegment()?.lemma
        )
    }

    // Returns the first query candidate for the current segment that has a dictionary hit.
    // Uses the same candidate ordering as history recording and Words-tab routing.
    private func resolvedLookupQueryForCurrentSelectedSegment() -> String? {
        guard let store = dictionaryStore else { return nil }

        for candidate in currentSelectedLookupCandidates() {
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(candidate) ? .kanjiAndKana : .kanaOnly
            if let entries = try? store.lookup(surface: candidate, mode: lookupMode),
               entries.isEmpty == false {
                return candidate
            }
        }

        return nil
    }

    // Returns the first dictionary entry resolved from the current segment using the same candidate ordering
    // as the Words-tab route so the sheet button state matches the actual open behavior.
    private func resolvedDictionaryEntryForCurrentSelectedSegment() -> DictionaryEntry? {
        guard let store = dictionaryStore else { return nil }
        guard let surface = currentSelectedSurface() else { return nil }
        let lookupMode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
        // Try the tapped surface directly — typically one logical lookup.
        if let entry = try? store.lookup(surface: surface, mode: lookupMode).first {
            return entry
        }
        // Inflected-form fallback. Use Lexicon's deinflector, NOT the segmenter, because the
        // segmenter is MeCab-based and picks a homograph lemma in cases like 合える
        // (potential form of 合う): MeCab returns 和える "to dress (vegetables)" which is the
        // wrong word entirely. Lexicon's deinflector follows JMdict-grounded inflection rules
        // and correctly produces 合う. The expensive part of Lexicon was the per-candidate
        // SQL gating; that's now backed by the in-memory POS-bits map, so this call is
        // pure CPU + hashtable lookups.
        guard let lemma = lexicon?.inflectionInfo(surface: surface)?.lemma, lemma != surface else {
            return nil
        }
        let lemmaMode: LookupMode = ScriptClassifier.containsKanji(lemma) ? .kanjiAndKana : .kanaOnly
        return (try? store.lookup(surface: lemma, mode: lemmaMode))?.first
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
