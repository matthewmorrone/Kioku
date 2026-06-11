import SwiftUI

extension ReadView {
    // Presents a stacked, full-chrome lookup sheet for a lemma surface that has no segment
    // context (e.g. tapping a row in the parent sheet's "Compound" section).
    //
    // Uses a fresh `SegmentLookupSheet` instance so the parent sheet sitting underneath keeps
    // its own providers untouched. Merge/split/prev/next callbacks are deliberately nil so the
    // corresponding chrome buttons gray themselves out — there is no segment lattice to drive
    // them. Save and Open-Detail remain functional because they only need a dictionary entry.
    //
    // Drilling further from the nested sheet recurses through the same method, stacking another
    // sheet on top.
    func presentNestedLemmaLookup(lemma: String, gloss: String?) {
        let nestedSheet = SegmentLookupSheet()

        // Resolves the first dictionary entry for the lemma, mirroring the surface→lemma
        // candidate ordering used by the primary lookup so the chrome's "open detail" button
        // routes consistently with the Words tab.
        func resolvedEntry() -> DictionaryEntry? {
            guard let store = dictionaryStore else { return nil }
            for candidate in orderedLookupCandidates(surface: lemma, lemma: nil) {
                let mode: LookupMode = ScriptClassifier.containsKanji(candidate) ? .kanjiAndKana : .kanaOnly
                if let entry = try? store.lookup(surface: candidate, mode: mode).first {
                    return entry
                }
            }
            return nil
        }

        // Collects unique kana readings for the lemma from both the lexicon and any matching
        // dictionary entries — same dual-source pattern as the primary segment reading list.
        func uniqueReadings() -> [String] {
            var readings: [String] = []
            var seen: Set<String> = []
            // Appends one reading to the result list iff it is non-empty and not already present.
            func append(_ reading: String?) {
                guard let reading, reading.isEmpty == false, seen.contains(reading) == false else { return }
                seen.insert(reading)
                readings.append(reading)
            }
            if let lexicon {
                for reading in lexicon.readings(surface: lemma) { append(reading) }
            }
            if let store = dictionaryStore {
                let mode: LookupMode = ScriptClassifier.containsKanji(lemma) ? .kanjiAndKana : .kanaOnly
                if let entries = try? store.lookup(surface: lemma, mode: mode) {
                    for entry in entries {
                        for kana in entry.kanaForms { append(kana.text) }
                    }
                }
            }
            return readings
        }

        // Looks up frequency for an arbitrary surface via the shared resolver (direct surface,
        // then deinflected lemmas, skipping frequency-less entries) so inflected forms and
        // split fragments still report something instead of a "—".
        func frequencyForSurface(_ surface: String) -> [String: FrequencyData]? {
            frequencyData(forSurface: surface)
        }

        // Recursive drill — tapping a compound row inside the nested sheet stacks yet another
        // nested sheet for that lemma. The closure captures `self` (ReadView), not `nestedSheet`,
        // so each recursion gets its own fresh SegmentLookupSheet instance.
        nestedSheet.onCompoundComponentTapped = { subLemma, subGloss in
            presentNestedLemmaLookup(lemma: subLemma, gloss: subGloss)
        }

        nestedSheet.presentSheet(
            surface: lemma,
            leftNeighborSurface: nil,
            rightNeighborSurface: nil,
            onSelectPrevious: nil,
            onSelectNext: nil,
            onMergeLeft: nil,
            onMergeRight: nil,
            onSplitApply: nil,
            sheetReadingsProvider: { uniqueReadings() },
            sheetSublatticeProvider: { [] },
            segmentRangeProvider: { nil },
            sheetLexiconDebugProvider: { "" },
            sheetFrequencyProvider: { frequencyForSurface(lemma) },
            sheetLemmaInfoProvider: { nil },
            onReadingSelected: nil,
            onReadingReset: nil,
            activeReadingOverrideProvider: nil,
            pathSegmentFrequencyProvider: { surface in
                frequencyForSurface(surface)
            },
            sheetDictionaryEntryProvider: { resolvedEntry() },
            sheetIsSavedProvider: { [weak nestedSheet] in
                // Filled star = saved AND attributed to this note (or saved with no note
                // attribution at all) — matches the extract-words list's isStarFilled encoding
                // now that the hollow-yellow "saved elsewhere" state exists below.
                guard let entry = nestedSheet?.currentSheetDictionaryEntry,
                      let word = wordsStore.words.first(where: { $0.canonicalEntryID == entry.entryId })
                else { return false }
                // return wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
                guard let activeNoteID else { return true }
                return word.sourceNoteIDs.isEmpty || word.sourceNoteIDs.contains(activeNoteID)
            },
            sheetIsSavedElsewhereProvider: { [weak nestedSheet] in
                // Hollow-yellow star: saved, but attributed only to other notes.
                guard let entry = nestedSheet?.currentSheetDictionaryEntry,
                      let word = wordsStore.words.first(where: { $0.canonicalEntryID == entry.entryId }),
                      let activeNoteID
                else { return false }
                return word.sourceNoteIDs.isEmpty == false && word.sourceNoteIDs.contains(activeNoteID) == false
            },
            sheetSaveToggle: { [weak nestedSheet] in
                guard let entry = nestedSheet?.currentSheetDictionaryEntry else { return }
                wordsStore.toggle(
                    canonicalEntryID: entry.entryId,
                    storedSurface: lemma,
                    encounteredSurface: lemma,
                    sourceNoteID: activeNoteID,
                    defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
                )
            },
            sheetOpenWordDetail: { [weak nestedSheet] in
                guard let entry = resolvedEntry() else { return }
                let reading = nestedSheet?.currentSheetUniqueReadings.first
                onOpenWordDetail?(entry.entryId, lemma, reading, [])
            },
            sheetWordComponentsProvider: { nil },
            sheetCompoundComponentsProvider: { lexicon?.compoundVerbComponents(surface: lemma) },
            onWillDismiss: nil,
            onDismiss: nil
        )
    }
}
