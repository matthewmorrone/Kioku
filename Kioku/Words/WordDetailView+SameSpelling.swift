import SwiftUI

// The Same Spelling list at the top of the page, mirroring the Read-tab lookup sheet's word list:
// the header arrows step through every reading of the spelling, and this list tells apart the words
// that share the reading shown, when there are several. Picking one switches the page to it in
// place rather than re-pointing this card.
extension WordDetailView {
    // Entries written with this word's kanji spelling as an everyday form, other than the one this
    // card is for (sameSpellingAllEntries orders them). Drawn from both the surface lookup (allDisplayData) and the
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
        return siblings
    }

    // This word and every other written the same way, in one fixed order — most frequent first,
    // ties by rank, then entry id — so the arrows and the list read the same from every word's page. Just this
    // word when it shares its spelling with none.
    var sameSpellingAllEntries: [DictionaryEntry] {
        guard let active = allDisplayData.first(where: { $0.entry.entryId == activeEntryID })?.entry else { return [] }
        return (sameSpellingEntries + [active]).sorted {
            let a = FrequencyData(frequencyRank: $0.frequencyRank, wordfreqZipf: $0.wordfreqZipf).normalizedScore ?? -1
            let b = FrequencyData(frequencyRank: $1.frequencyRank, wordfreqZipf: $1.wordfreqZipf).normalizedScore ?? -1
            if a != b { return a > b }
            // Homophones share a kana spelling's wordfreq count, so equal scores go by each entry's own rank.
            let ranks = ($0.frequencyRank ?? Int.max, $1.frequencyRank ?? Int.max)
            return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : $0.entryId < $1.entryId
        }
    }

    // The words sharing the reading the switcher stands on, folded like the lookup sheet's list:
    // folded, only this word's row (highlighted, "+N ⌄"); unfolded, all of them. Shown only when
    // the reading is several words. Tapping this word's row folds or unfolds; tapping another
    // switches the page to it on the same reading, recorded as a lookup like Related Words.
    @ViewBuilder
    var sameSpellingSection: some View {
        let readings = switchableReadings
        let currentReading = currentSwitchIndex.map { readings[$0].reading }
        let sharing = currentReading.map { reading in
            sameSpellingAllEntries.filter { offeredReadings(of: $0).contains(reading) }
        } ?? []
        if sharing.count > 1,
           let active = sharing.first(where: { $0.entryId == activeEntryID }) {
            let others = sharing.count - 1
            let shown = sameSpellingExpanded.wrappedValue ? sharing : [active]
            Section {
                ForEach(shown, id: \.entryId) { entry in
                    let isActive = entry.entryId == active.entryId
                    Button {
                        if isActive {
                            withAnimation { sameSpellingExpanded.wrappedValue.toggle() }
                        } else {
                            historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
                            openSameSpellingWord(entry, reading: currentReading)
                        }
                    } label: {
                        HStack {
                            relatedWordRow(entry)
                            if isActive {
                                Text(sameSpellingExpanded.wrappedValue ? "⌃" : "+\(others) ⌄")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isActive ? Color(.tertiarySystemFill) : nil)
                    .accessibilityLabel(isActive
                        ? (sameSpellingExpanded.wrappedValue ? "Hide words with this reading" : "Show \(others) more words with this reading")
                        : entry.primarySearchSurface)
                }
            }
        }
    }

    // The fold state this page's list uses: its owner's on a stand-in page, else its own.
    var sameSpellingExpanded: Binding<Bool> {
        sameSpellingExpandedBinding ?? $isSameSpellingExpanded
    }

    // Switches the page to a same-spelling word in place, opened on `reading`. A stand-in page hands
    // the pick to the page that owns it, so switching never nests; picking that page's own word
    // switches back at once (it never left) and shows the reading. Any other word is mounted hidden
    // and shown when it reports ready (showSameSpellingPage). A word the user has saved opens as its
    // saved card, anything else as an unsaved one.
    func openSameSpellingWord(_ entry: DictionaryEntry, reading: String?) {
        if let onOpenSameSpelling {
            onOpenSameSpelling(entry, reading)
            return
        }
        guard entry.entryId != activeEntryID else {
            visibleSameSpellingID = nil
            sameSpellingPages = []
            if let reading { showOwnReading(reading) }
            return
        }
        if let reading { sameSpellingPageReadings[entry.entryId] = reading }
        if sameSpellingPages.contains(where: { $0.canonicalEntryID == entry.entryId }) {
            showSameSpellingPage(entry.entryId)
            return
        }
        sameSpellingPages.append(
            wordsStore.words.first { $0.canonicalEntryID == entry.entryId } ?? ephemeralSavedWord(for: entry)
        )
    }

    // Brings a loaded same-spelling page to the front and unmounts the others it replaced.
    func showSameSpellingPage(_ entryID: Int64) {
        guard sameSpellingPages.contains(where: { $0.canonicalEntryID == entryID }) else { return }
        visibleSameSpellingID = entryID
        sameSpellingPages.removeAll { $0.canonicalEntryID != entryID }
    }
}
