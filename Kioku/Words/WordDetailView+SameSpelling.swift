import SwiftUI

// The "Same Spelling" section: other dictionary words written the same way as this one (抱く read
// いだく vs だく), mirroring the Read-tab lookup sheet's word list. The header arrows only cycle this
// word's own readings, so the other words live here, and each opens its own detail page rather than
// re-pointing this card.
extension WordDetailView {
    // Entries written with this word's kanji spelling as an everyday form, other than the one this
    // card is for, most frequent first. Drawn from both the surface lookup (allDisplayData) and the
    // reading gathering (readingVariants), since each finds siblings the other can miss. The
    // spelling is the saved surface when the entry writes it that way, else the entry's everyday
    // kanji (an inflected surface like 抱かれ → 抱く). Kana-only words have no shared spelling here.
    var sameSpellingEntries: [DictionaryEntry] {
        guard let active = allDisplayData.first(where: { $0.entry.entryId == activeEntryID })?.entry else { return [] }
        let spelling = active.kanjiForms.contains { $0.text == word.surface }
            ? word.surface
            : active.firstEverydayKanji?.text
        guard let spelling, ScriptClassifier.containsKanji(spelling) else { return [] }
        var seen: Set<Int64> = [activeEntryID]
        let pool = allDisplayData.map(\.entry) + readingVariants.compactMap(\.entry)
        let siblings = pool.filter { entry in
            guard seen.insert(entry.entryId).inserted else { return false }
            return entry.kanjiForms.contains {
                $0.text == spelling && DictionaryEntry.kanjiFormIsNonEveryday(info: $0.info) == false
            }
        }
        return siblings.sorted {
            let a = FrequencyData(frequencyRank: $0.frequencyRank, wordfreqZipf: $0.wordfreqZipf).normalizedScore ?? -1
            let b = FrequencyData(frequencyRank: $1.frequencyRank, wordfreqZipf: $1.wordfreqZipf).normalizedScore ?? -1
            return a > b
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
