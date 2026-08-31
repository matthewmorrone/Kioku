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

    // Returns the first dictionary entry resolved from the current segment using the same candidate ordering
    // as the Words-tab route so the sheet button state matches the actual open behavior.
    // Not private: also called from currentSegmentDictionaryEntry in ReadView+Segmentation.swift.
    func resolvedDictionaryEntryForCurrentSelectedSegment() -> DictionaryEntry? {
        guard let surface = currentSelectedSurface() else { return nil }
        return resolvedDictionaryEntry(forSurface: surface)
    }
}
