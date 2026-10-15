import SwiftUI

// Header reading switcher: left/right chevrons flank the headword and cycle every reading of the
// word's spelling, mirroring the Read-tab lookup sheet's arrows — the entry's own readings (涙 →
// なみだ / なだ) and those of other entries written the same way (抱く → だく / いだく / うだく,
// three JMdict entries). A reading of another entry switches the page to that word in place
// (openSameSpellingWord); this card is never re-pointed. Words sharing one reading are told apart
// by the Same Spelling list (WordDetailView+SameSpelling).
extension WordDetailView {
    // Which direction an arrow advances the active reading.
    enum ReadingSwitchDirection {
        case previous
        case next
    }

    // Every reading of the spelling, entry by entry in the Same Spelling order (so the stops read
    // the same from every word's page), each tied to its entry; a reading two entries share is one
    // stop, on the first. Empty or single → the switcher stays hidden. Kana-written words have no
    // switcher: the kana is the reading.
    var switchableReadings: [ReadingVariants.Variant] {
        guard ScriptClassifier.containsKanji(word.surface) else { return [] }
        var seen = Set<String>()
        return sameSpellingAllEntries.flatMap { entry in
            offeredReadings(of: entry).compactMap { reading in
                seen.insert(reading).inserted
                    ? ReadingVariants.Variant(reading: reading, lemma: word.surface, chain: [], entry: entry)
                    : nil
            }
        }
    }

    // One entry's kana forms that apply to its kanji, minus search-only forms, katakana copies of a
    // hiragana reading, and (unless DictionarySettings.includeArchaicReadings) obsolete or
    // irregular ones — the active entry's current reading is always kept so a word saved on one
    // still shows it.
    func offeredReadings(of entry: DictionaryEntry) -> [String] {
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
            let isCurrent = entry.entryId == activeEntryID
                && (form.text == activeReading || form.text == savedChosenReading)
            if isObscure, includeArchaic == false, isCurrent == false { continue }
            if readings.contains(form.text) == false { readings.append(form.text) }
        }
        return readings
    }

    // Where the switcher stands: this entry's stop for the reading shown (or saved), else this
    // entry's first stop. Nil when this entry offers none.
    var currentSwitchIndex: Int? {
        let readings = switchableReadings
        return readings.firstIndex {
            $0.entry?.entryId == activeEntryID && ($0.reading == activeReading || $0.reading == savedChosenReading)
        } ?? readings.firstIndex { $0.entry?.entryId == activeEntryID }
    }

    // The reading the user picked with the switcher on some earlier visit, read off the live saved
    // card for whichever entry is active now (so a re-point this session can't surface the previous
    // entry's reading). An unsaved word falls back to the reading on its History row. Nil when
    // neither has one, or when it isn't a dictionary reading (a custom one recorded before custom
    // readings stayed in the Read view).
    var savedChosenReading: String? {
        let saved = wordsStore.words.first { $0.canonicalEntryID == activeEntryID }?.selectedReading
            ?? historyStore.reading(for: activeEntryID)
        return saved.flatMap { isDictionaryReading($0) ? $0 : nil }
    }

    // Whether `reading` is one of the word's dictionary readings: a kana form of an entry spelled
    // like it, as written or projected onto the surface (抱かれ read だかれ is だく's). A custom
    // reading pinned in the Read view isn't — it belongs to that place in the text (地球 sung ほし),
    // so this page never shows it as the word's reading. False until the entries load.
    func isDictionaryReading(_ reading: String) -> Bool {
        sameSpellingAllEntries.contains { entry in
            entry.kanaForms.contains { form in
                form.text == reading
                    || projectedReading(surface: word.surface, baseReading: form.text,
                                        kanjiForms: entry.kanjiForms, kanaForms: entry.kanaForms) == reading
            }
        }
    }

    // The reading this view was opened with, when it's a dictionary reading.
    var openedDictionaryReading: String? {
        reading.flatMap { isDictionaryReading($0) ? $0 : nil }
    }

    // The custom reading of the occurrence this view was opened from (the lookup sheet's), shown
    // as a note under the header — "read ほし here" — so the header's dictionary reading doesn't
    // look like the custom one was lost. Nil once the switcher flips or the entry is re-pointed,
    // and while the entries load (when no reading can be told custom yet).
    var customOccurrenceReading: String? {
        guard displayedReading == nil, activeEntryID == word.canonicalEntryID,
              sameSpellingAllEntries.isEmpty == false,
              let reading, isDictionaryReading(reading) == false else { return nil }
        return reading
    }

    // The reading of the text occurrence this view was opened from (the lookup sheet's header), when
    // it differs from the card's pinned reading. The Words list passes the pinned reading itself, so
    // a differing value can only come from an occurrence, and it wins so the header matches the sheet
    // the user just left (抱かれながら read だ in the text must not open as いだ). Nil once the
    // switcher flips or the entry is re-pointed.
    var occurrenceReading: String? {
        guard displayedReading == nil, activeEntryID == word.canonicalEntryID,
              let reading = openedDictionaryReading, reading != savedChosenReading else { return nil }
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
        let reading = openedDictionaryReading
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

    // Advances to the previous/next reading with wrap-around (matching the lookup sheet). A reading
    // of this entry flips the header furigana (projected onto an inflected surface) and persists
    // the pick onto the saved card (see persistChosenReading) so it also shows in the Words list,
    // on reopen, and on study cards. A reading of another entry switches the page to that word,
    // opened on that reading.
    func switchReading(_ direction: ReadingSwitchDirection, among readings: [ReadingVariants.Variant]) {
        guard readings.count > 1 else { return }
        let total = readings.count
        let currentIndex = currentSwitchIndex ?? 0
        let nextIndex = direction == .next
            ? (currentIndex + 1) % total
            : (currentIndex - 1 + total) % total
        let target = readings[nextIndex]
        guard let entry = target.entry, entry.entryId != activeEntryID else {
            showOwnReading(target.reading)
            return
        }
        openSameSpellingWord(entry, reading: target.reading)
    }

    // Shows one of this entry's readings in the header and saves it as the card's pick.
    func showOwnReading(_ reading: String) {
        let entry = allDisplayData.first { $0.entry.entryId == activeEntryID }?.entry
        displayedReading = entry.map {
            projectedReading(surface: word.surface, baseReading: reading,
                             kanjiForms: $0.kanjiForms, kanaForms: $0.kanaForms) ?? reading
        } ?? reading
        persistChosenReading(reading)
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
