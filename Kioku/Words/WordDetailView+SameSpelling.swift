import SwiftUI

// The Same Spelling list at the top of the page: other dictionary words written the same way as
// this one (抱く read いだく vs だく), mirroring the Read-tab lookup sheet's word list. The header arrows only cycle this
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

    // The words written this way, at the top of the page and folded like the lookup sheet's list:
    // this word's own row (highlighted) with "+N ⌄" to unfold the rest; tapping it again folds
    // them away. Tapping another word switches this page to it (openSameSpellingWord), recorded as
    // a lookup like the Related Words rows.
    @ViewBuilder
    var sameSpellingSection: some View {
        let siblings = sameSpellingEntries
        if siblings.isEmpty == false,
           let active = allDisplayData.first(where: { $0.entry.entryId == activeEntryID })?.entry {
            Section {
                Button {
                    withAnimation { isSameSpellingExpanded.toggle() }
                } label: {
                    HStack {
                        relatedWordRow(active)
                        Text(isSameSpellingExpanded ? "⌃" : "+\(siblings.count) ⌄")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(.tertiarySystemFill))
                .accessibilityLabel(isSameSpellingExpanded ? "Hide words with the same spelling" : "Show \(siblings.count) words with the same spelling")
                if isSameSpellingExpanded {
                    ForEach(siblings, id: \.entryId) { entry in
                        Button {
                            historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
                            openSameSpellingWord(entry)
                        } label: {
                            relatedWordRow(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // Switches the page to a same-spelling word in place. A stand-in page hands the pick to the
    // page that owns it, so switching never nests; picking that page's own word switches back.
    // A word the user has saved opens as its saved card, anything else as an unsaved one.
    func openSameSpellingWord(_ entry: DictionaryEntry) {
        if let onOpenSameSpelling {
            onOpenSameSpelling(entry)
            return
        }
        guard entry.entryId != activeEntryID else {
            sameSpellingWord = nil
            return
        }
        sameSpellingWord = wordsStore.words.first { $0.canonicalEntryID == entry.entryId }
            ?? ephemeralSavedWord(for: entry)
    }
}
