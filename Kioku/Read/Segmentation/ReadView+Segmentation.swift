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

        // Apply the override to each target via the shared per-run helper — it clears stale
        // overlapping entries first, then projects `reading` over the kanji runs so okurigana
        // never ends up inside the highlighted word's furigana.
        if let selectedSurface {
            for (targetLocation, _) in targets {
                applyPerRunFurigana(surface: selectedSurface, reading: reading, at: targetLocation)
            }
        }
        // A pinned reading is a genuine user edit — enable the reset button.
        hasManualSegmentationEdits = true
        // Rebuild segments with updated furigana then persist.
        rebuildAndPersistSegments()
    }

    // Removes the persisted reading for the currently selected segment and re-runs furigana
    // computation so the auto-derived default refills the gap. The transient blanking flag
    // is also set so the UI shows no ruby until the recompute finishes — without that, the
    // user's old override would briefly remain visible during the async backfill.
    func clearReadingOverrideForCurrentSegment() {
        guard let location = selectedSegmentLocation else { return }
        // Unpinning a reading is a user edit too (it overrides the persisted reading back to the
        // auto-derived default), so the reset button should stay available.
        hasManualSegmentationEdits = true
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
        hasManualSegmentationEdits = false
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
        // Corrections were just cleared, so the next AI run should go straight through.
        hasAppliedLLMCorrectionForCurrentNote = false
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
        // Single canonical entry point for tap timing regardless of origin (main CoreText view
        // or LyricsView) — previously only KiokuCoreTextView.handleTap called beginTap(), so taps
        // routed through LyricsView never started the clock and every TapDiagnostics.mark(...)
        // downstream silently no-opped, leaving no diagnostic trail for lyrics-view popover bugs.
        TapDiagnostics.beginTap()
        TapDiagnostics.mark("handleReadModeSegmentTap entered")
        defer { TapDiagnostics.mark("handleReadModeSegmentTap returning") }
        // If the tapped segment has a pending LLM change, show what changed instead of the lookup sheet.
        if let tappedSegmentLocation,
           let changeDescription = pendingLLMChangesByLocation[tappedSegmentLocation] {
            TapDiagnostics.mark("BAIL: pendingLLMChangesByLocation match, showing LLM change popover instead")
            llmChangePopoverText = changeDescription
            llmChangePopoverLocation = tappedSegmentLocation
            isShowingLLMChangePopover = true
            return
        }

        guard let tappedSegmentLocation else {
            TapDiagnostics.mark("BAIL: tappedSegmentLocation is nil (tapped empty space)")
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        if selectedSegmentLocation == tappedSegmentLocation {
            TapDiagnostics.mark("BAIL: tapped the already-selected segment (toggle-off)")
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        // Highlight state is set unconditionally and immediately, matching pre-existing behavior —
        // only the dictionary-backed lookup below needs to wait for resources.
        selectedSegmentLocation = tappedSegmentLocation
        selectedHighlightRangeOverride = nil
        selectedBounds = initialMergedEdgeBounds(for: tappedSegmentLocation)
        // debugPrintLatticeSectionForCurrentSelection(at: tappedSegmentLocation)

        // Dictionary resources (segmenter trie/deinflector) may still be loading in the first
        // moment or two after app launch. A conjugated word's lookup needs preferredLemma, which
        // needs the loaded trie, and silently fails with no feedback if it isn't ready yet — plain
        // dictionary-form words work anyway since the raw surface itself is a valid candidate, so
        // this only bites conjugated words tapped right at startup. Queue and replay the lookup
        // once ready instead of leaving it looking like nothing happened. Goes through the
        // extracted presentLookupForSegmentTap (not another handleReadModeSegmentTap call) since
        // selectedSegmentLocation is already set to this location by the time the replay fires —
        // re-entering here would hit the toggle-off branch above and deselect instead of look up.
        guard readResourcesReady else {
            TapDiagnostics.mark("QUEUED: readResourcesReady == false, will replay lookup once resources finish loading")
            pendingSegmentTapAfterResourcesReady = (location: tappedSegmentLocation, rect: tappedSegmentRect, sourceView: sourceView)
            return
        }

        presentLookupForSegmentTap(tappedSegmentLocation: tappedSegmentLocation, tappedSegmentRect: tappedSegmentRect, sourceView: sourceView)
    }

    // The dictionary-lookup/presentation half of a segment tap, split out from
    // handleReadModeSegmentTap so the startup-race replay (see the readResourcesReady guard
    // above) can re-run just this part without re-triggering the toggle-off check.
    func presentLookupForSegmentTap(tappedSegmentLocation: Int, tappedSegmentRect: CGRect?, sourceView: UIScrollView?) {
        let adjacentSurfaces = adjacentSegmentSurfaces(for: tappedSegmentLocation)

        if prefersSheetDirectSegmentActions {
            TapDiagnostics.mark("taking presentFullLookupSheet path (prefersSheetDirectSegmentActions)")
            presentFullLookupSheet(
                tappedSegmentLocation: tappedSegmentLocation,
                adjacentSurfaces: adjacentSurfaces,
                sourceView: sourceView,
                tappedSegmentRect: tappedSegmentRect
            )
            return
        }

        guard let definitionPayload = definitionPayloadForSelectedSegment(at: tappedSegmentLocation) else {
            TapDiagnostics.mark("BAIL: definitionPayloadForSelectedSegment(at:) returned nil")
            SegmentLookupSheet.shared.dismissPopover()
            return
        }

        guard let sourceView, let tappedSegmentRect else {
            TapDiagnostics.mark("BAIL: sourceView or tappedSegmentRect is nil (sourceView=\(sourceView != nil), rect=\(tappedSegmentRect != nil))")
            SegmentLookupSheet.shared.dismissPopover()
            return
        }
        TapDiagnostics.mark("about to call presentPopover")

        SegmentLookupSheet.shared.presentPopover(
            definition: definitionPayload.definition,
            surface: definitionPayload.surface,
            isSavedProvider: { isSegmentSaved() },
            isSavedElsewhereProvider: { isSegmentSavedElsewhere() },
            onSaveToggle: { toggleSegmentSaved() },
            learnedStateProvider: { currentSegmentLearnedState() },
            onSetLearnedState: { setCurrentSegmentLearnedState($0) },
            onEscalate: {
                presentFullLookupSheet(
                    tappedSegmentLocation: tappedSegmentLocation,
                    adjacentSurfaces: adjacentSurfaces,
                    sourceView: sourceView,
                    tappedSegmentRect: tappedSegmentRect
                )
            },
            onDismiss: {
                clearSelectedSegmentStateAfterPopoverDismissal()
            },
            sourceView: sourceView,
            sourceRect: tappedSegmentRect
        )
    }

    // Presents the full lookup sheet for the tapped segment — readings, definitions, frequency
    // split, sublattice, merge/split controls. Shared by the direct-tap path
    // (prefersSheetDirectSegmentActions) and the popover's escalate arrow (onEscalate), so both
    // routes into the full sheet always carry the identical rich provider set.
    private func presentFullLookupSheet(
        tappedSegmentLocation: Int,
        adjacentSurfaces: (left: String?, right: String?),
        sourceView: UIScrollView?,
        tappedSegmentRect: CGRect?
    ) {
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
            // Tell the sheet whether frequency data is loaded yet so its split readout shows a loading
            // state instead of all-zero scores when opened mid-startup; onChange(of: frequencyDataReady)
            // flips it true and refreshes the open readout once the reading map lands (Stage 1, ~1s).
            SegmentLookupSheet.shared.frequencyResourcesReady = frequencyDataReady
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
                // with the reading. Two populations, both needed:
                //
                // 1) Inflected surfaces (e.g. 触れられない) — we admit both 触れる (depth 2) and
                //    触る (depth 3); each contributes a surface-projected reading
                //    (ふれられない / さわれられない) and its dictionary entry, so arrowing flips
                //    the lemma label and gloss panel.
                //
                // 2) Dictionary surfaces with multiple JMdict entries (e.g. 様, 方, 中, 何) —
                //    these used to be skipped under the assumption that one entry covers all
                //    readings, but kanji like 様 are actually split across separate JMdict
                //    entries (さま honorific vs よう manner-suffix). For each direct reading,
                //    look up the entry whose kana form matches that reading specifically.
                //    Without this, the gloss panel and the displayed reading drift apart on
                //    first paint — the resolver picks the higher-frequency さま entry while
                //    the controller's reading-cycle starts on よう.
                //
                // Surface projection for #1 is critical because bare lemma readings are shorter
                // than the inflected surface's okurigana tail (sheetReadingsProvider returns
                // projected readings, so this map must key on the same strings).
                sheetLemmaInfoByReadingProvider: {
                    let surface = currentSelectedSurface() ?? ""
                    guard surface.isEmpty == false, let lexicon, let store = dictionaryStore else { return [:] }
                    var byReading: [String: (lemma: String, chain: [String], entry: DictionaryEntry?)] = [:]

                    // Path 1: lemma-projected readings. For each (lemma, reading), prefer the
                    // JMdict entry whose kana form matches the reading — that disambiguates
                    // homographic kanji like 様 (さま honorific vs よう manner-suffix), 方
                    // (かた vs ほう), 中 (なか vs ちゅう), etc. Falls back to the lemma's
                    // highest-priority entry when the reading is non-canonical (inflected
                    // surfaces project an okurigana tail onto the lemma reading, e.g.
                    // 触れる/ふれる → ふれられない, which won't match any JMdict kana form).
                    for group in lexicon.surfaceReadingsByLemma(surface: surface) {
                        let lemmaMode: LookupMode = ScriptClassifier.containsKanji(group.lemma) ? .kanjiAndKana : .kanaOnly
                        let lemmaFallback = (try? store.lookup(surface: group.lemma, mode: lemmaMode))?.first
                        for reading in group.surfaceReadings where byReading[reading] == nil {
                            let perReadingEntry = lexicon.lookupLexeme(group.lemma, reading).first
                            byReading[reading] = (lemma: group.lemma, chain: group.chain, entry: perReadingEntry ?? lemmaFallback)
                        }
                    }

                    // Path 2: kana-only or dictionary surfaces not admitted as a lemma by Path 1.
                    if let data = surfaceReadingData[surface], data.readings.isEmpty == false {
                        for reading in data.readings where byReading[reading] == nil {
                            let entry = lexicon.lookupLexeme(surface, reading).first
                            byReading[reading] = (lemma: surface, chain: [], entry: entry)
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
                    // Shared resolver: direct surface entry, then deinflected lemmas, skipping
                    // frequency-less entries so a bare split fragment still reports its lemma's
                    // score instead of a "—". (Was an inline copy that short-circuited on the
                    // empty-but-present case — see frequencyData(forSurface:).)
                    frequencyData(forSurface: surface)
                },
                sheetDictionaryEntryProvider: {
                    resolvedDictionaryEntryForCurrentSelectedSegment()
                },
                sheetIsSavedProvider: { isSegmentSaved() },
                sheetIsSavedElsewhereProvider: { isSegmentSavedElsewhere() },
                sheetSaveToggle: { toggleSegmentSaved() },
                sheetLearnedStateProvider: { currentSegmentLearnedState() },
                sheetSetLearnedState: { setCurrentSegmentLearnedState($0) },
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
    }

    // Resolves the tapped segment surface and the best-ordered gloss from dictionary results.
    func definitionPayloadForSelectedSegment(at selectedLocation: Int) -> (surface: String, definition: String)? {
        guard
            let tappedSegmentRange = segmentRanges.first(where: { segmentRange in
                let nsRange = NSRange(segmentRange, in: text)
                return nsRange.location == selectedLocation && nsRange.length > 0
            })
        else {
            TapDiagnostics.mark("definitionPayload: no segmentRange matches location=\(selectedLocation) (segmentRanges.count=\(segmentRanges.count))")
            return nil
        }

        let tappedSurface = String(text[tappedSegmentRange])
        if shouldIgnoreSegmentForDefinitionLookup(tappedSurface) {
            TapDiagnostics.mark("definitionPayload: shouldIgnoreSegmentForDefinitionLookup(\(tappedSurface)) == true")
            return nil
        }

        // Diagnostic: isolate whether preferredLemma itself is flaking at call time (vs. this
        // segmenter instance being genuinely different/incomplete from the one integration
        // tests exercise). Calls it twice and separately checks a plain dictionary-form word
        // (no deinflection needed at all) to rule out a totally-empty/placeholder segmenter.
        let lemmaAttempt1 = segmenter.preferredLemma(for: tappedSurface)
        let lemmaAttempt2 = segmenter.preferredLemma(for: tappedSurface)
        let plainWordLemma = segmenter.preferredLemma(for: "さがす")
        TapDiagnostics.mark("definitionPayload: preferredLemma(\(tappedSurface))=\(lemmaAttempt1 ?? "nil")/\(lemmaAttempt2 ?? "nil"), preferredLemma(さがす)=\(plainWordLemma ?? "nil"), segmenterType=\(type(of: segmenter))")

        let lookupCandidates = orderedLookupCandidates(surface: tappedSurface, lemma: lemmaAttempt1)
        TapDiagnostics.mark("definitionPayload: surface=\(tappedSurface), candidates=\(lookupCandidates)")
        for lookupCandidate in lookupCandidates {
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(lookupCandidate) ? .kanjiAndKana : .kanaOnly
            do {
                guard let entries = try dictionaryStore?.lookup(surface: lookupCandidate, mode: lookupMode) else {
                    TapDiagnostics.mark("definitionPayload: dictionaryStore?.lookup(\(lookupCandidate)) returned nil (dictionaryStore nil? \(dictionaryStore == nil))")
                    continue
                }
                TapDiagnostics.mark("definitionPayload: \(lookupCandidate) → \(entries.count) entries")

                if let mostLikelyDefinition = mostLikelyDefinition(from: entries) {
                    return (surface: tappedSurface, definition: mostLikelyDefinition)
                }
                TapDiagnostics.mark("definitionPayload: mostLikelyDefinition(from:) nil for \(lookupCandidate)'s \(entries.count) entries")
            } catch {
                TapDiagnostics.mark("definitionPayload: lookup(\(lookupCandidate)) threw \(error)")
                continue
            }
        }

        // Fallback: compound verbs (さがしつづける = さがし-stem + auxiliary つづける) collapse to
        // one segment via Deinflector's compoundVerbRecoveryForms, and preferredLemma(for:) on the
        // FULL compound relies on that single special-cased rule matching exactly — any mismatch
        // (POS-gating edge case, trie lookup miss) leaves lookupCandidates with only the raw
        // surface, which isn't itself a dictionary headword, so the loop above finds nothing. The
        // sublattice still holds the natural two-token split as its own edges (さがし → さがす,
        // つづける → 続ける) independent of that special rule; try it before giving up entirely.
        if let split = LatticeEdge.auxiliaryVerbSplit(
            from: sublatticeEdgesForCurrentSelectedSegment(),
            auxiliaries: DerivationAnalyzer.auxiliaryVerbs,
            lemmaResolver: { segmenter.preferredLemma(for: $0, preferring: DerivationAnalyzer.auxiliaryVerbs) }
        ) {
            let resolvedBase = segmenter.preferredLemma(for: split[0]) ?? split[0]
            TapDiagnostics.mark("definitionPayload: retrying via auxiliaryVerbSplit base=\(resolvedBase)")
            let lookupMode: LookupMode = ScriptClassifier.containsKanji(resolvedBase) ? .kanjiAndKana : .kanaOnly
            if let entries = try? dictionaryStore?.lookup(surface: resolvedBase, mode: lookupMode),
               let mostLikelyDefinition = mostLikelyDefinition(from: entries) {
                return (surface: tappedSurface, definition: mostLikelyDefinition)
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

    // Same shared "filled star" predicate the extract-words list and the glow use, so all three
    // agree 1:1. Keyed on the lemma (the form the extract list stars) so an inflected segment
    // reflects the favorite state of its dictionary word. Shared by both the full sheet and the
    // lightweight popover so their star state can't drift apart.
    func isSegmentSaved() -> Bool {
        guard let surface = currentSelectedSurface() else { return false }
        let resolver: (String) -> String? = { segmenter.preferredLemma(for: $0) }
        let (state, _) = SegmentListView.computeSavedWordState(
            entries: wordsStore.words,
            lemmaResolver: resolver,
            lemmaCache: [:]
        )
        return state.isStarFilled(
            surface.trimmingCharacters(in: .whitespacesAndNewlines),
            noteID: activeNoteID,
            lemmaResolver: resolver
        )
    }

    // Hollow-yellow star: saved, but attributed only to other notes. Same shared predicate the
    // extract-words list uses for its yellow outline star.
    func isSegmentSavedElsewhere() -> Bool {
        guard let surface = currentSelectedSurface() else { return false }
        let resolver: (String) -> String? = { segmenter.preferredLemma(for: $0) }
        let (state, _) = SegmentListView.computeSavedWordState(
            entries: wordsStore.words,
            lemmaResolver: resolver,
            lemmaCache: [:]
        )
        return state.isSavedForOtherNotes(
            surface.trimmingCharacters(in: .whitespacesAndNewlines),
            noteID: activeNoteID,
            lemmaResolver: resolver
        )
    }

    // Toggles the saved state for the current segment's resolved lemma. Prefers the
    // reading-disambiguated async entry (currentSheetDictionaryEntry), falling back to the
    // synchronous segment resolver when it hasn't landed yet — see the "star doesn't always
    // bookmark" fix this mirrors.
    func toggleSegmentSaved() {
        guard let surface = currentSelectedSurface(),
              let entry = currentSegmentDictionaryEntry() else { return }
        let lemma = segmenter.preferredLemma(for: surface)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (lemma?.isEmpty == false ? lemma! : surface)
        wordsStore.toggle(
            canonicalEntryID: entry.entryId,
            storedSurface: key,
            encounteredSurface: key,
            sourceNoteID: activeNoteID,
            defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
        )
    }

    // The dictionary entry backing the currently selected/shown segment — same resolution
    // toggleSegmentSaved uses, factored out so the learned-state provider/setter below read
    // the identical entry rather than risking a second, slightly different resolution.
    private func currentSegmentDictionaryEntry() -> DictionaryEntry? {
        SegmentLookupSheet.shared.currentSheetDictionaryEntry
            ?? resolvedDictionaryEntryForCurrentSelectedSegment()
    }

    // The star's long-press learned-state menu for the current segment, mirroring the Words tab.
    func currentSegmentLearnedState() -> LearnedState {
        guard let entry = currentSegmentDictionaryEntry() else { return .unmarked }
        return wordsStore.learnedState(for: entry.entryId)
    }

    // Writes the mark for the current segment's resolved entry. Learned/Not-Learned means
    // saved by definition, so this ensures the card exists first — same lemma-preferring
    // surface key as toggleSegmentSaved above, so the created card matches what tapping the
    // star directly would have produced.
    func setCurrentSegmentLearnedState(_ state: LearnedState) {
        guard let surface = currentSelectedSurface(),
              let entry = currentSegmentDictionaryEntry() else { return }
        let lemma = segmenter.preferredLemma(for: surface)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (lemma?.isEmpty == false ? lemma! : surface)
        wordsStore.setLearnedState(
            state,
            for: entry.entryId,
            ensureSavedWithSurface: key,
            sourceNoteID: activeNoteID,
            defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
        )
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
    // JMdict orders both entries and senses most-common-usage-first, so the first non-empty
    // gloss in that order IS the most likely definition — no need to re-rank by anything else.
    // A prior version sorted by gloss character count instead, which backfired for words whose
    // primary sense happens to have a longer gloss than a rarer one: を's primary sense "indicates
    // direct object of action" (sense 0) lost to the area-traversal sense "indicates an area
    // traversed" (sense 2) purely because the latter string is shorter, surfacing the wrong
    // meaning for the most common particle in the language.
    func mostLikelyDefinition(from entries: [DictionaryEntry]) -> String? {
        for entry in entries {
            for sense in entry.senses {
                for gloss in sense.glosses {
                    let trimmedGloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedGloss.isEmpty == false {
                        return trimmedGloss
                    }
                }
            }
        }
        return nil
    }

}
