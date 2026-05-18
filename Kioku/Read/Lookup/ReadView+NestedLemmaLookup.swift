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

        // Looks up frequency for an arbitrary surface, with the same lemma-fallback hop the
        // primary sheet uses so inflected forms still report something.
        func frequencyForSurface(_ surface: String) -> [String: FrequencyData]? {
            if let data = surfaceReadingData[surface]?.frequencyByReading {
                return data
            }
            guard let lexicon else { return nil }
            for base in lexicon.lemma(surface: surface) {
                if let data = surfaceReadingData[base]?.frequencyByReading {
                    return data
                }
            }
            return nil
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
                guard let entry = nestedSheet?.currentSheetDictionaryEntry else { return false }
                return wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
            },
            sheetSaveToggle: { [weak nestedSheet] in
                guard let entry = nestedSheet?.currentSheetDictionaryEntry else { return }
                if wordsStore.words.contains(where: { $0.canonicalEntryID == entry.entryId }) {
                    wordsStore.remove(id: entry.entryId)
                } else {
                    let sourceIDs = activeNoteID.map { [$0] } ?? []
                    let senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
                    wordsStore.add(
                        SavedWord(
                            canonicalEntryID: entry.entryId,
                            surface: lemma,
                            sourceNoteIDs: sourceIDs,
                            selectedSenseIDs: senseIDs
                        )
                    )
                }
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
