import SwiftUI

// The "Same Spelling" section: other dictionary words written the same way as this one (抱く read
// いだく vs だく), mirroring the Read-tab lookup sheet's word list. The header arrows only cycle this
// word's own readings, so the other words live here, and each opens its own detail page rather than
// re-pointing this card.
extension WordDetailView {
    // Entries sharing this word's everyday kanji spelling, other than the one this card is for, in
    // the order the reading gathering found them (see loadDisplayData's heteronyms).
    var sameSpellingEntries: [DictionaryEntry] {
        var seen: Set<Int64> = [activeEntryID]
        return readingVariants.compactMap { variant in
            guard let entry = variant.entry, seen.insert(entry.entryId).inserted else { return nil }
            return entry
        }
    }

    // One row per same-spelling word; tapping opens that word's detail page on top of this one,
    // recorded as a lookup like the Related Words rows.
    @ViewBuilder
    var sameSpellingSection: some View {
        let entries = sameSpellingEntries
        if entries.isEmpty == false {
            Section {
                ForEach(entries, id: \.entryId) { entry in
                    Button {
                        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
                        presentedRelatedSavedWord = ephemeralSavedWord(for: entry)
                    } label: {
                        relatedWordRow(entry)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Same Spelling")
            } footer: {
                Text("Other words written the same way. The arrows switch this word's own readings.")
            }
        }
    }
}
