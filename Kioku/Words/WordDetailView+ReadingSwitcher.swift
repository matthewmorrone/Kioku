import SwiftUI

// Header reading switcher: when a kanji word has several readings that share its spelling, left/right
// chevrons flank the headword and cycle between them, mirroring the Read-tab lookup sheet's arrows.
// Two cases, both offered (the sheet dedupes readings by STRING, so this does too, rather than the
// old dedup-by-entry that hid the second case):
//   • Cross-entry heteronyms (抱く → いだく / だく / うだく — distinct JMdict entries). Switching
//     re-points the saved word to that reading's entry so the Definition follows the reading.
//   • Within-entry kana variants (涙 → なみだ / なだ — one entry, same meaning). Switching only swaps
//     the displayed furigana; the entry and Definition stay put.
extension WordDetailView {
    // Which direction an arrow advances the active reading.
    enum ReadingSwitchDirection {
        case previous
        case next
    }

    // The readings the switcher offers: one per distinct reading STRING (so a single entry's several
    // kana readings each appear, matching the sheet), archaic/obscure-only readings dropped unless the
    // user opted in (the active reading is always kept so a word saved on its archaic reading still
    // shows). Empty or single → the switcher stays hidden.
    var switchableReadings: [ReadingVariants.Variant] {
        let includeArchaic = DictionarySettings.includeArchaicReadings
        var seen = Set<String>()
        return readingVariants.compactMap { variant in
            guard seen.insert(variant.reading).inserted else { return nil }
            let isActive = variant.reading == activeReading
            let entryArchaic = variant.entry.map { DefaultSenseSelection.isEntirelyLowPriority($0) } ?? false
            guard includeArchaic || isActive || entryArchaic == false else { return nil }
            return variant
        }
    }

    // The reading the user picked with the switcher on some earlier visit, read off the live saved
    // card for whichever entry is active now (so a re-point this session can't surface the previous
    // entry's reading). Nil when the word isn't saved or was never switched.
    var savedChosenReading: String? {
        wordsStore.words.first { $0.canonicalEntryID == activeEntryID }?.selectedReading
    }

    // The reading to render above the headword. Once the switcher flips (either case), displayedReading
    // is authoritative. Then a reading persisted by an earlier flip — a deliberate choice, so it
    // outranks both the sheet-supplied reading and the entry default — projected onto the surface the
    // same way a live flip is. Otherwise: the exact reading handed in by the lookup sheet while still
    // on the opened entry, else the active homograph's projected reading (いだかれ → だかれ).
    func headerReading(entry: DictionaryEntry?) -> String? {
        if let displayedReading { return displayedReading }
        if let chosen = savedChosenReading {
            let forms = switchableReadings.first { $0.reading == chosen }?.entry ?? entry
            guard let forms else { return chosen }
            return projectedReading(
                surface: word.surface,
                baseReading: chosen,
                kanjiForms: forms.kanjiForms,
                kanaForms: forms.kanaForms
            ) ?? chosen
        }
        if activeEntryID == word.canonicalEntryID, let reading { return reading }
        if let active = switchableReadings.first(where: { $0.entry?.entryId == activeEntryID }),
           let activeEntry = active.entry {
            return projectedReading(
                surface: word.surface,
                baseReading: active.reading,
                kanjiForms: activeEntry.kanjiForms,
                kanaForms: activeEntry.kanaForms
            ) ?? reading
        }
        return reading ?? inflectedReading(surface: word.surface, entry: entry)
    }

    // One flanking chevron, shown only when there is more than one reading to cycle. Rendered as a
    // leading/trailing overlay on the headword row so it doesn't shift the centered title.
    @ViewBuilder
    func readingSwitcherChevron(_ direction: ReadingSwitchDirection) -> some View {
        let readings = switchableReadings
        if readings.count > 1 {
            Button {
                switchReading(direction, among: readings)
            } label: {
                Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(direction == .previous ? "Previous Reading" : "Next Reading")
        }
    }

    // Advances to the previous/next reading with wrap-around (matching the lookup sheet). Always sets
    // displayedReading so the header furigana flips; when the target reading belongs to a DIFFERENT
    // entry (a heteronym) it also re-points the saved word via the shared homonym switch path so the
    // Definition follows. Within-entry readings share one entry, so only the furigana changes.
    // Either way the choice is persisted onto the saved card (see persistChosenReading) so it also
    // shows in the Words list, on reopen, and on study cards — not just in this open view.
    func switchReading(_ direction: ReadingSwitchDirection, among readings: [ReadingVariants.Variant]) {
        guard readings.count > 1 else { return }
        let total = readings.count
        // Locate the active item by reading string first (works for within-entry flips), falling back
        // to the active entry (the opened state, before any flip, when displayedReading is nil).
        let currentIndex = readings.firstIndex { $0.reading == activeReading }
            ?? readings.firstIndex { $0.entry?.entryId == activeEntryID }
            ?? 0
        let nextIndex = direction == .next
            ? (currentIndex + 1) % total
            : (currentIndex - 1 + total) % total
        let target = readings[nextIndex]
        // Project the target onto the (possibly inflected) surface for display, mirroring headerReading.
        displayedReading = target.entry.map {
            projectedReading(surface: word.surface, baseReading: target.reading,
                             kanjiForms: $0.kanjiForms, kanaForms: $0.kanaForms) ?? target.reading
        } ?? target.reading
        if let targetEntryID = target.entry?.entryId, targetEntryID != activeEntryID {
            switchSavedEntry(to: targetEntryID)
        }
        // After any re-point, so the reading lands on the entry the card now points at (repoint
        // rebuilds the card and clears the old entry's reading — see WordsStore.repoint).
        persistChosenReading(target.reading)
        // switchSavedEntry arms a scroll-into-view meant for tapping a homonym card far down the
        // list. The switcher already shows only the active reading in place, so cancel that scroll
        // to keep the header steady while cycling readings.
        scrollTargetEntryID = nil
    }

    // Writes the switcher's pick onto the saved card. Stores the target's PLAIN dictionary reading,
    // not the inflected projection shown in the header (いだかれ → だかれ): the card's stored surface
    // is the lemma, so every other reader — the Words list row, the study cards — needs the lemma's
    // reading to pair with it. A no-op when the entry isn't saved (the detail view also opens for
    // unsaved search results and nested related-word lookups); nothing to record there.
    func persistChosenReading(_ reading: String) {
        wordsStore.setReading(id: activeEntryID, reading: reading)
    }
}
