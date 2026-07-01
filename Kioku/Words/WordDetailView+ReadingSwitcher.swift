import SwiftUI

// Header reading switcher: when a kanji word has several readings that share its spelling
// (抱く → いだく / だく / うだく — distinct JMdict entries, not one entry with sense restrictions),
// left/right chevrons flank the headword and cycle between them, mirroring the Read-tab lookup
// sheet's arrows. Switching re-points the saved word to that reading's entry (reusing the existing
// homonym re-point path) so the furigana and the Definition section both follow the active reading.
extension WordDetailView {
    // Which direction an arrow advances the active reading.
    enum ReadingSwitchDirection {
        case previous
        case next
    }

    // The readings the switcher actually offers: one per distinct entry, archaic/obscure-only
    // readings dropped unless the user opted in (the active reading is always kept so a word saved
    // on its archaic reading still shows). Empty or single → the switcher stays hidden.
    var switchableReadings: [ReadingVariants.Variant] {
        let includeArchaic = DictionarySettings.includeArchaicReadings
        var seen = Set<Int64>()
        return readingVariants.compactMap { variant in
            guard let entry = variant.entry, seen.insert(entry.entryId).inserted else { return nil }
            let isActive = entry.entryId == activeEntryID
            guard includeArchaic || isActive || DefaultSenseSelection.isEntirelyLowPriority(entry) == false else { return nil }
            return variant
        }
    }

    // The reading to render above the headword. Prefers the exact reading handed in by the lookup
    // sheet while the word is still on the entry it was opened with; once the user switches readings
    // it derives from the active homograph so the furigana flips (いだかれ → だかれ).
    func headerReading(entry: DictionaryEntry?) -> String? {
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

    // Advances to the previous/next reading with wrap-around (matching the lookup sheet) and
    // re-points the saved word to that reading's entry via the shared homonym switch path, which
    // persists the change and reloads the screen around the newly active reading.
    func switchReading(_ direction: ReadingSwitchDirection, among readings: [ReadingVariants.Variant]) {
        guard readings.count > 1 else { return }
        let total = readings.count
        let currentIndex = readings.firstIndex { $0.entry?.entryId == activeEntryID } ?? 0
        let nextIndex = direction == .next
            ? (currentIndex + 1) % total
            : (currentIndex - 1 + total) % total
        guard let target = readings[nextIndex].entry?.entryId, target != activeEntryID else { return }
        switchSavedEntry(to: target)
        // switchSavedEntry arms a scroll-into-view meant for tapping a homonym card far down the
        // list. The switcher already shows only the active reading in place, so cancel that scroll
        // to keep the header steady while cycling readings.
        scrollTargetEntryID = nil
    }
}
