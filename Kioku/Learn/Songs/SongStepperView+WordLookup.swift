import SwiftUI

// Word lookup for the song breakdown (see SongStepperView): a tapped breakdown word resolves to a
// dictionary entry, picked in context where several words share its spelling, and opens the shared
// lookup sheet; the sheet's star saves it against this note.
extension SongStepperView {

    // Resolves a tapped breakdown word to a dictionary entry and opens the shared lookup sheet.
    // Tries the sung surface first, then the segmenter's lemma for conjugated forms (歌った → 歌う)
    // that don't resolve directly; silently no-ops when there's no dictionary or no entry.
    func presentWordLookup(_ word: SongWord, in line: SongLine) {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false, let dictionaryStore else { return }

        let entryID: Int64?
        if let contextual = contextualEntryID(surface: surface, in: line) {
            entryID = contextual
        } else if let direct = dictionaryStore.lookupFirstEntryID(surface: surface) {
            entryID = direct
        } else if let lemma = segmenter?.preferredLemma(for: surface), lemma.isEmpty == false {
            entryID = dictionaryStore.lookupFirstEntryID(surface: lemma)
        } else {
            entryID = nil
        }
        guard let entryID else { return }

        SegmentLookupSheet.shared.presentSheet(
            surface: surface,
            leftNeighborSurface: nil,
            rightNeighborSurface: nil,
            sheetReadingsProvider: {
                guard let entry = try? dictionaryStore.lookupEntry(entryID: entryID) else { return [] }
                return entry.kanaForms.map(\.text)
            },
            sheetDictionaryEntryProvider: {
                try? dictionaryStore.lookupEntry(entryID: entryID)
            },
            sheetIsSavedProvider: {
                wordsStore.words.contains { $0.canonicalEntryID == entryID }
            },
            sheetSaveToggle: {
                toggleSavedWord(canonicalEntryID: entryID, surface: surface)
            },
            sheetLearnedStateProvider: {
                wordsStore.learnedState(for: entryID)
            },
            sheetSetLearnedState: { state in
                wordsStore.setLearnedState(state, for: entryID, ensureSavedWithSurface: surface)
            }
        )
    }

    // The word `surface` is in this line when several share its spelling: the line is segmented and the
    // words either side of the matching segment pick between them (ContextualClassChoice, the same
    // choice the lookup sheet makes). Nil when the spelling is one word, matches no segment, or context
    // does not decide, and the tap falls back to the top entry.
    func contextualEntryID(surface: String, in line: SongLine) -> Int64? {
        guard let lexicon, let segmenter,
              let table = (segmenter as? Segmenter)?.transitionTable else { return nil }
        let candidates = lexicon.lookupCandidates(surface: surface)
        guard candidates.count > 1 else { return nil }
        let edges = segmenter.longestMatchEdges(for: line.original)
        guard let index = edges.firstIndex(where: { $0.surface == surface }) else { return nil }
        let neighbours = ContextualClassChoice.Neighbours(
            previous: index > 0 ? edges[index - 1] : nil,
            next: index + 1 < edges.count ? edges[index + 1] : nil
        )
        return Lexicon.contextuallyPreferredCandidate(
            among: candidates,
            surface: surface,
            neighbours: neighbours,
            table: table
        )?.entry.entryId
    }

    // Flips saved state for a looked-up breakdown word, attributing it to this note. Mirrors the
    // segment-list toggle: only pay the SQL sense-materialization on a word's first-ever save.
    func toggleSavedWord(canonicalEntryID: Int64, surface: String) {
        let cardExists = wordsStore.words.contains { $0.canonicalEntryID == canonicalEntryID }
        let senseIDs: [Int64]
        if cardExists {
            senseIDs = []
        } else if let dictionaryStore, let resolved = try? dictionaryStore.lookupEntry(entryID: canonicalEntryID) {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
        } else {
            senseIDs = []
        }
        wordsStore.toggle(
            canonicalEntryID: canonicalEntryID,
            storedSurface: surface,
            encounteredSurface: surface,
            sourceNoteID: note.id,
            defaultSenseIDs: senseIDs
        )
    }
}
