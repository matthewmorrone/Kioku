import SwiftUI
import UIKit

// The full lookup sheet's provider wiring for a tapped segment — split out of
// ReadView+Segmentation.swift to keep that file under the line-count guardrail. Shared by the
// direct-tap path (prefersSheetDirectSegmentActions) and the popover's escalate arrow, both in
// presentLookupForSegmentTap (ReadView+Segmentation.swift).
extension ReadView {
    // Presents the full lookup sheet for the tapped segment — readings, definitions, frequency
    // split, sublattice, merge/split controls. Shared by the direct-tap path
    // (prefersSheetDirectSegmentActions) and the popover's escalate arrow (onEscalate), so both
    // routes into the full sheet always carry the identical rich provider set.
    func presentFullLookupSheet(
        tappedSegmentLocation: Int,
        adjacentSurfaces: (left: String?, right: String?),
        sourceView: UIScrollView?,
        tappedSegmentRect: CGRect?
    ) {
            guard let segmentSurface = surfaceForSegment(at: tappedSegmentLocation) else {
                SegmentLookupSheet.shared.dismissPopover()
                return
            }

            let noteReading = reconstructedReading(for: segmentSurface, at: tappedSegmentLocation)
            recordLookupHistory(surface: segmentSurface, reading: noteReading.isEmpty ? nil : noteReading)

            // Drilling into a compound component row spawns a stacked, full-chrome lookup sheet
            // for the tapped lemma. Installed here so the closure captures the current ReadView
            // value (its dictionaryStore/lexicon/wordsStore references are already there).
            SegmentLookupSheet.shared.onCompoundComponentTapped = { lemma, gloss in
                presentNestedLemmaLookup(lemma: lemma, gloss: gloss)
            }
            // Picking one of an ambiguous form's words (いった → 言う) saves the pick with the segment.
            SegmentLookupSheet.shared.onLookupCandidateChosen = { entryID in
                applyLookupCandidateChoice(entryID: entryID)
            }

            // Record where the view is and plan every scroll for this tap from there. The sheet's own
            // size isn't known until it has measured its new content. Opening a sheet: scroll right
            // away against the last height a sheet had on screen (skipped when none has been shown
            // yet) while it slides in, then re-plan when it reports its real height. Switching words
            // in an open sheet: don't move yet — the sheet reports once the new word's content is in,
            // so the view moves once. The tapped rect is in content coordinates, so it holds across
            // scrolls. (The view-mode reader is a plain UIScrollView, not a UITextView, so the rect
            // can't be re-derived from a text view.)
            editModeScroll.sheetScrollStartOffsetY = sourceView?.contentOffset.y
            if SegmentLookupSheet.shared.hasActivePresentedSheetController == false,
               SegmentLookupSheet.shared.lastPresentedSheetHeight != nil {
                preScrollSegmentForSheetVisibility(
                    sourceView: sourceView,
                    tappedSegmentRect: tappedSegmentRect,
                    replanningFromStart: true
                )
            }
            // A word with no dictionary entry gets a guessed gloss, from its line and this note's
            // song breakdown when there is one. Reads the selection at call time, so a word reached
            // with the sheet's previous/next arrows gets its own line.
            SegmentLookupSheet.shared.glossGuessProvider = { surface in
                let location = segmentSelection.selectedSegmentLocation ?? tappedSegmentLocation
                let text = document.text as NSString
                let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
                let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                let breakdownWords = document.activeNoteID
                    .flatMap { songBreakdownStore.breakdown(forNoteID: $0) }?
                    .lines.flatMap(\.words) ?? []
                return await GlossGuesser.guess(surface: surface, lineContext: line, breakdownWords: breakdownWords)
            }
            // A word with no dictionary entry that JMnedict knows as a name shows its name readings.
            SegmentLookupSheet.shared.nameLookupProvider = { surface in
                guard let dictionaryStore else { return [] }
                do {
                    return try dictionaryStore.lookupNames(surface: surface)
                } catch {
                    AppLog.error(.dictionary, "Name lookup failed for \(surface): \(error)")
                    return []
                }
            }
            // An unknown katakana word that is a regular respelling of a dictionary word (カステイラ →
            // カステラ, an older loanword spelling) shows that word as a guess, before any AI guess.
            SegmentLookupSheet.shared.spellingGuessProvider = { surface in
                guard ScriptClassifier.isPureKatakana(surface), let dictionaryStore else { return nil }
                return await Task.detached(priority: .userInitiated) {
                    do {
                        return try dictionaryStore.katakanaSpellingGuess(for: surface)
                    } catch {
                        AppLog.error(.dictionary, "Spelling guess failed for \(surface): \(error)")
                        return nil
                    }
                }.value
            }
            // Learn Spelling closes the lookup sheet and opens the form for the word.
            SegmentLookupSheet.shared.learnSpellingHandler = { surface in
                SegmentLookupSheet.shared.dismissPopover {
                    readSheets.learnSpellingSurface = surface
                    readSheets.isShowingLearnSpelling = true
                }
            }
            SegmentLookupSheet.shared.onSheetHeightChanged = {
                // The word now selected, which the sheet's arrows may have moved off the tapped one.
                let selectedRect = segmentSelection.selectedSegmentLocation
                    .flatMap { selectedSegmentRect(in: sourceView, selectedLocation: $0) }
                preScrollSegmentForSheetVisibility(
                    sourceView: sourceView,
                    tappedSegmentRect: selectedRect ?? tappedSegmentRect,
                    replanningFromStart: true
                )
            }

            // Tell the sheet whether the segmenter is loaded yet so its split readout shows a loading
            // state instead of missing costs when opened mid-startup; the segmenterRevision change in
            // ReadView+Lifecycle flips it true and re-costs the open readout once it lands.
            SegmentLookupSheet.shared.splitCostsReady = readResourcesReady
            SegmentLookupSheet.shared.presentSheet(
                surface: segmentSurface,
                leftNeighborSurface: adjacentSurfaces.left,
                rightNeighborSurface: adjacentSurfaces.right,
                onSelectPrevious: {
                    // Planned like a tap: from here, once the sheet reports its height for the
                    // new word (it does even when the height is unchanged), so the view moves once.
                    editModeScroll.isSheetSwipeTransitionActive = true
                    editModeScroll.sheetScrollStartOffsetY = sourceView?.contentOffset.y
                    let outcome = moveSelectedSegmentSelection(isMovingForward: false)
                    Task { @MainActor in
                        await Task.yield()
                        editModeScroll.isSheetSwipeTransitionActive = false
                    }
                    return outcome
                },
                onSelectNext: {
                    // Planned like a tap: from here, once the sheet reports its height for the
                    // new word (it does even when the height is unchanged), so the view moves once.
                    editModeScroll.isSheetSwipeTransitionActive = true
                    editModeScroll.sheetScrollStartOffsetY = sourceView?.contentOffset.y
                    let outcome = moveSelectedSegmentSelection(isMovingForward: true)
                    Task { @MainActor in
                        await Task.yield()
                        editModeScroll.isSheetSwipeTransitionActive = false
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
                    ReadingVariants.orderedReadings(
                        surface: currentSelectedSurface() ?? "",
                        lexicon: lexicon,
                        segmenter: segmenter,
                        surfaceReadingData: surfaceReadingData
                    )
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
                // Per-reading lemma map: lets the arrow controls cycle the lemma + gloss along with
                // the reading. Two populations, both needed:
                //   1) Inflected surfaces (e.g. 触れられない) — we admit both 触れる (depth 2) and 触る (depth 3);
                //      each contributes a surface-projected reading (ふれられない / さわれられない) and its dictionary
                //      entry, so arrowing flips the lemma label and gloss panel.
                //   2) Dictionary surfaces with multiple JMdict entries (e.g. 様, 方, 中, 何) — one entry does not
                //      cover all readings: 様 is split across separate JMdict entries (さま honorific vs よう
                //      manner-suffix). For each direct reading, look up the entry whose kana form matches that reading
                //      specifically. Without this, the gloss panel and the displayed reading drift apart on first
                //      paint — the resolver picks the higher-frequency さま entry while the controller's reading-cycle
                //      starts on よう.
                // Surface projection for #1 is critical because bare lemma readings are shorter
                // than the inflected surface's okurigana tail (sheetReadingsProvider returns
                // projected readings, so this map must key on the same strings).
                // Path 1 disambiguates homographic kanji like 様 (さま honorific vs よう
                // manner-suffix), 方 (かた vs ほう), 中 (なか vs ちゅう) by preferring the JMdict
                // entry whose kana form matches the reading, falling back to the lemma's
                // highest-priority entry when the reading is non-canonical (inflected surfaces
                // project an okurigana tail onto the lemma reading, e.g. 触れる/ふれる →
                // ふれられない, which won't match any JMdict kana form).
                sheetLemmaInfoByReadingProvider: {
                    let surface = currentSelectedSurface() ?? ""
                    guard surface.isEmpty == false, let lexicon, let store = dictionaryStore else { return [:] }
                    return ReadingVariants.lemmaInfoByReading(
                        surface: surface,
                        lexicon: lexicon,
                        store: store,
                        surfaceReadingData: surfaceReadingData
                    )
                },
                onReadingSelected: { reading in
                    applyReadingOverride(reading: reading)
                },
                onReadingReset: {
                    clearReadingOverrideForCurrentSegment()
                },
                activeReadingOverrideProvider: {
                    guard let location = segmentSelection.selectedSegmentLocation,
                          let edge = document.segmentEdges.first(where: {
                              NSRange($0.start..<$0.end, in: document.text).location == location
                          }) else { return nil }
                    if segmentSelection.transientBlankReadingSegmentLocation == location {
                        return nil
                    }
                    let reading = reconstructedReading(for: edge.surface, at: location)
                    return reading.isEmpty ? nil : reading
                },
                splitCostsProvider: { candidates in
                    splitCostsForCurrentSelectedSegment(candidates)
                },
                sheetDictionaryEntryProvider: {
                    resolvedDictionaryEntryForCurrentSelectedSegment()
                },
                sheetIsSavedProvider: { isSegmentSaved() },
                sheetSaveToggle: { toggleSegmentSaved() },
                sheetLearnedStateProvider: { currentSegmentLearnedState() },
                sheetSetLearnedState: { setCurrentSegmentLearnedState($0) },
                sheetOpenWordDetail: { shownReading, shownEntry in
                    // An ambiguous form with no pick has no word to open.
                    guard SegmentLookupSheet.shared.isAwaitingLookupCandidatePick == false else { return }
                    guard let surface = currentSelectedSurface(),
                          let entry = shownEntry ?? resolvedDictionaryEntryForCurrentSelectedSegment() else { return }
                    // A picked word opens as itself (言う / いう), not as the form it was tapped in.
                    let candidates = SegmentLookupSheet.shared.currentSheetLookupCandidates
                    if candidates.count > 1, let picked = candidates.first(where: { $0.entry.entryId == entry.entryId }) {
                        onOpenWordDetail?(entry.entryId, picked.headword, picked.reading, [])
                        return
                    }
                    let reading = shownReading ?? SegmentLookupSheet.shared.currentSheetUniqueReadings.first
                    let paths = LatticeEdge.validPaths(from: SegmentLookupSheet.shared.currentSheetSublatticeEdges)
                    onOpenWordDetail?(entry.entryId, surface, reading, paths)
                },
                // Deferred to Breakdown expansion (see sheetReadingsProvider comment).
                sheetWordComponentsProvider: { nil },
                // One row per word the lemma line names (起こる + そう), each with its meaning.
                sheetCompoundComponentsProvider: {
                    guard let line = lemmaInfoForCurrentSelectedSegment()?.lemma else { return nil }
                    return lexicon?.lemmaLineComponents(line)?.map { (lemma: $0.lemma, gloss: $0.gloss) }
                },
                sheetLookupCandidatesProvider: {
                    guard let surface = currentSelectedSurface(), let lexicon else { return (candidates: [], chosenEntryID: nil) }
                    let chosen = segmentSelection.selectedSegmentLocation.flatMap { document.chosenEntryIDBySegmentLocation[$0] }
                    return (candidates: lexicon.lookupCandidates(surface: surface), chosenEntryID: chosen)
                },
                onWillDismiss: { completion in
                    restoreScrollAfterSheetDismissal(sourceView: sourceView, completion: completion)
                },
                onDismiss: {
                    editModeScroll.isSheetSwipeTransitionActive = false
                    clearSelectedSegmentStateAfterPopoverDismissal()
                }
            )
    }

    // Returns the first dictionary entry resolved from the current segment using the same candidate ordering
    // as the Words-tab route so the sheet button state matches the actual open behavior.
    // Not private: also called from currentSegmentDictionaryEntry in ReadView+Segmentation.swift.
    func resolvedDictionaryEntryForCurrentSelectedSegment() -> DictionaryEntry? {
        guard let surface = currentSelectedSurface() else { return nil }
        return resolvedDictionaryEntry(forSurface: surface)
    }
}
