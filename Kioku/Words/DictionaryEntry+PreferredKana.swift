import Foundation

extension DictionaryEntry {
    // Returns the kana reading that matches the user's selected senses, honoring JMdict
    // stagr restrictions (a sense applying only to specific kana forms). Per JMdict semantics,
    // a sense with stagr restrictions applies only to the listed readings; a sense without
    // stagr applies to every reading. Intersecting per-sense valid readings yields the set
    // valid for the whole selection, and the first kana form in entry order is returned.
    // Falls back to `kanaForms.first?.text` when nothing is selected or the intersection
    // would be empty (which only happens with inconsistent selections that aren't producible
    // through the UI today).
    nonisolated func preferredKana(
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        senseRestrictions: [SenseRestriction]
    ) -> String? {
        let fallback = kanaForms.first?.text
        guard kanaForms.isEmpty == false else { return fallback }
        let validKana = formsValidForSelection(
            kanaForms.map(\.text), kind: .stagr,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
            senseRestrictions: senseRestrictions
        )
        return validKana.first ?? fallback
    }

    // Every spelling a learner may type for this word in a production quiz: the everyday kanji forms
    // and the everyday readings (no rare, outdated, irregular or search-only forms) that apply to the
    // selected senses under stagk/stagr. 分かる also accepts 解る; 明日 as a reading accepts あした and あす.
    nonisolated func acceptedSpellings(
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        senseRestrictions: [SenseRestriction]
    ) -> (kanji: [String], kana: [String]) {
        let everydayKanji = kanjiForms
            .filter { DictionaryEntry.kanjiFormIsNonEveryday(info: $0.info) == false }
            .map(\.text)
        let everydayKana = kanaForms
            .filter { DictionaryEntry.kanaFormIsNonEveryday(info: $0.info) == false }
            .map(\.text)
        let kanji = formsValidForSelection(
            everydayKanji, kind: .stagk,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
            senseRestrictions: senseRestrictions
        )
        let kana = formsValidForSelection(
            everydayKana, kind: .stagr,
            selectedSenseIDs: selectedSenseIDs, selectedGlosses: selectedGlosses,
            senseRestrictions: senseRestrictions
        )
        return (kanji, kana)
    }

    // ik/ok/sk readings (irregular, outdated, search-only) are not spellings a learner should be
    // taught, so a quiz never accepts them as an answer.
    nonisolated static func kanaFormIsNonEveryday(info: String?) -> Bool {
        guard let info, info.isEmpty == false else { return false }
        return info.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { ["ik", "ok", "sk"].contains($0) }
    }

    // The subset of `forms` (kept in entry order) that every selected sense applies to: a sense with
    // restrictions of `kind` applies only to the listed forms, one without applies to all. Nothing
    // selected, or an empty intersection (an inconsistent selection), leaves `forms` unfiltered.
    private nonisolated func formsValidForSelection(
        _ forms: [String],
        kind: SenseRestrictionKind,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef],
        senseRestrictions: [SenseRestriction]
    ) -> [String] {
        var selectedIndexes = Set<Int>()
        for senseID in selectedSenseIDs + selectedGlosses.map(\.senseID) {
            if let idx = senses.firstIndex(where: { $0.senseID == senseID }) {
                selectedIndexes.insert(idx)
            }
        }
        var valid = Set(forms)
        for senseIdx in selectedIndexes {
            let restricted = senseRestrictions
                .filter { $0.senseOrderIndex == senseIdx && $0.type == kind }
                .map(\.value)
            if restricted.isEmpty { continue }
            valid.formIntersection(restricted)
        }
        guard valid.isEmpty == false else { return forms }
        return forms.filter { valid.contains($0) }
    }

    // The English meanings that match the user's selection, in selection precedence and
    // de-duplicated: whole-sense selections contribute that sense's first gloss; gloss-level
    // selections contribute that exact gloss text. When nothing is selected (or selections
    // didn't survive a dictionary rebuild), falls back to the entry's first sense's first gloss.
    // This is the single source of truth for "which definition is chosen" — the flashcard back
    // face, the multiple-choice prompt, and the Words-list row all resolve through it so a
    // selection change in WordDetailView shows up identically everywhere.
    nonisolated func selectedMeanings(
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef]
    ) -> [String] {
        var sensesByID: [Int64: DictionaryEntrySense] = [:]
        for sense in senses { sensesByID[sense.senseID] = sense }

        var meanings: [String] = []
        var seen: Set<String> = []
        // Adds a meaning to the running list after trimming and de-duplicating.
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else { return }
            meanings.append(trimmed)
        }

        for senseID in selectedSenseIDs {
            if let first = sensesByID[senseID]?.glosses.first { append(first) }
        }
        for ref in selectedGlosses {
            if let sense = sensesByID[ref.senseID],
               ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                append(sense.glosses[ref.glossIndex])
            }
        }
        if meanings.isEmpty, let first = senses.first?.glosses.first { append(first) }
        return meanings
    }
}
