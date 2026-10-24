import Foundation

extension WordsStore {
    // The word model WordDetailView opens for an entry: the saved card when there is one (showing
    // the surface actually being looked up, not whichever one it was first saved under, so
    // derivation, forms and the header reflect an inflected or compound occurrence), else a
    // temporary card from the surface hint. Nil when the entry is unsaved and no hint was given.
    // Shared by the Words tab and the Read tab so both open a word the same way.
    func detailWord(entryID: Int64, surfaceHint: String?) -> SavedWord? {
        if let saved = words.first(where: { $0.canonicalEntryID == entryID }) {
            if let surfaceHint, surfaceHint.isEmpty == false, surfaceHint != saved.surface {
                return SavedWord(
                    canonicalEntryID: saved.canonicalEntryID,
                    surface: surfaceHint,
                    sourceNoteIDs: saved.sourceNoteIDs,
                    wordListIDs: saved.wordListIDs,
                    personalNote: saved.personalNote,
                    savedAt: saved.savedAt,
                    selectedSenseIDs: saved.selectedSenseIDs,
                    selectedGlosses: saved.selectedGlosses,
                    encounteredSurfaces: saved.encounteredSurfaces,
                    entSeq: saved.entSeq,
                    hasBeenOrphaned: saved.hasBeenOrphaned
                )
            }
            return saved
        }
        if let surfaceHint, surfaceHint.isEmpty == false {
            return SavedWord(canonicalEntryID: entryID, surface: surfaceHint)
        }
        return nil
    }
}
