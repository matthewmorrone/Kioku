import SwiftUI

// Header reading switcher: when a kanji word's own dictionary entry has several readings (涙 →
// なみだ / なだ, 下手 したて → したて / したで), left/right chevrons flank the headword and cycle
// them, mirroring the Read-tab lookup sheet's arrows. The arrows never change which word this
// card is for: other words with the same spelling (抱く いだく vs だく) are listed in the Same
// Spelling section (WordDetailView+SameSpelling), each opening its own page.
extension WordDetailView {
    // Which direction an arrow advances the active reading.
    enum ReadingSwitchDirection {
        case previous
        case next
    }

    // The readings the switcher offers: the active entry's own kana forms that apply to its kanji,
    // minus search-only forms, katakana copies of a hiragana reading, and (unless
    // DictionarySettings.includeArchaicReadings) obsolete or irregular ones — the active reading
    // is always kept so a word saved on one still shows it. Empty or single → the switcher stays
    // hidden. Kana-written words have no switcher: the kana is the reading.
    var switchableReadings: [ReadingVariants.Variant] {
        guard ScriptClassifier.containsKanji(word.surface),
              let entry = allDisplayData.first(where: { $0.entry.entryId == activeEntryID })?.entry
        else { return [] }
        let includeArchaic = DictionarySettings.includeArchaicReadings
        let forms = entry.kanaForms.filter { $0.nokanji == false }
        let texts = Set(forms.map(\.text))
        var readings: [String] = []
        for form in forms {
            let tags = (form.info ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tags.contains("sk") { continue }
            let hiragana = KanaNormalizer.katakanaToHiragana(form.text)
            if hiragana != form.text, texts.contains(hiragana) { continue }
            let isObscure = tags.contains("ok") || tags.contains("ik")
            let isActive = form.text == activeReading || form.text == savedChosenReading
            if isObscure, includeArchaic == false, isActive == false { continue }
            if readings.contains(form.text) == false { readings.append(form.text) }
        }
        return readings.map { ReadingVariants.Variant(reading: $0, lemma: word.surface, chain: [], entry: entry) }
    }

    // The reading the user picked with the switcher on some earlier visit, read off the live saved
    // card for whichever entry is active now (so a re-point this session can't surface the previous
    // entry's reading). An unsaved word falls back to the reading on its History row. Nil when
    // neither has one.
    var savedChosenReading: String? {
        wordsStore.words.first { $0.canonicalEntryID == activeEntryID }?.selectedReading
            ?? historyStore.reading(for: activeEntryID)
    }

    // The reading of the text occurrence this view was opened from (the lookup sheet's header), when
    // it differs from the card's pinned reading. The Words list passes the pinned reading itself, so
    // a differing value can only come from an occurrence, and it wins so the header matches the sheet
    // the user just left (抱かれながら read だ in the text must not open as いだ). Nil once the
    // switcher flips or the entry is re-pointed.
    var occurrenceReading: String? {
        guard displayedReading == nil, activeEntryID == word.canonicalEntryID,
              let reading, reading != savedChosenReading else { return nil }
        return reading
    }

    // The reading to render above the headword. Once the switcher flips (either case), displayedReading
    // is authoritative. Then the occurrence reading from the lookup sheet (see occurrenceReading).
    // Then a reading persisted by an earlier flip — a deliberate choice, so it outranks the entry
    // default — projected onto the surface the same way a live flip is. Otherwise: the opened reading
    // while still on the opened entry, else the active homograph's projected reading (いだかれ → だかれ).
    func headerReading(entry: DictionaryEntry?) -> String? {
        if let displayedReading { return displayedReading }
        if let occurrenceReading { return occurrenceReading }
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

    // Advances to the previous/next reading with wrap-around (matching the lookup sheet). Sets
    // displayedReading so the header furigana flips (projected onto an inflected surface), and
    // persists the pick onto the saved card (see persistChosenReading) so it also shows in the Words
    // list, on reopen, and on study cards. The entry never changes: every reading here is its own.
    func switchReading(_ direction: ReadingSwitchDirection, among readings: [ReadingVariants.Variant]) {
        guard readings.count > 1 else { return }
        let total = readings.count
        // The active item by its plain reading; the header may show a projection (いだかれ), so the
        // saved pick is tried too before starting from the first.
        let currentIndex = readings.firstIndex { $0.reading == activeReading }
            ?? readings.firstIndex { $0.reading == savedChosenReading }
            ?? 0
        let nextIndex = direction == .next
            ? (currentIndex + 1) % total
            : (currentIndex - 1 + total) % total
        let target = readings[nextIndex]
        displayedReading = target.entry.map {
            projectedReading(surface: word.surface, baseReading: target.reading,
                             kanjiForms: $0.kanjiForms, kanaForms: $0.kanaForms) ?? target.reading
        } ?? target.reading
        persistChosenReading(target.reading)
    }

    // Writes the switcher's pick onto the saved card and the word's History row. Stores the target's PLAIN dictionary reading,
    // not the inflected projection shown in the header (いだかれ → だかれ): the card's stored surface
    // is the lemma, so every other reader — the Words list row, the study cards — needs the lemma's
    // reading to pair with it. Each write is a no-op where the entry has no card or no History row.
    func persistChosenReading(_ reading: String) {
        wordsStore.setReading(id: activeEntryID, reading: reading)
        historyStore.setReading(canonicalEntryID: activeEntryID, reading: reading)
    }
}
