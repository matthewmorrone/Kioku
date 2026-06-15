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

        var selectedIndexes = Set<Int>()
        for senseID in selectedSenseIDs {
            if let idx = senses.firstIndex(where: { $0.senseID == senseID }) {
                selectedIndexes.insert(idx)
            }
        }
        for ref in selectedGlosses {
            if let idx = senses.firstIndex(where: { $0.senseID == ref.senseID }) {
                selectedIndexes.insert(idx)
            }
        }
        guard selectedIndexes.isEmpty == false else { return fallback }

        let allKanaTexts = Set(kanaForms.map(\.text))
        var validKana = allKanaTexts
        for senseIdx in selectedIndexes {
            let stagrForSense = senseRestrictions
                .filter { $0.senseOrderIndex == senseIdx && $0.type == .stagr }
                .map(\.value)
            if stagrForSense.isEmpty { continue }
            validKana.formIntersection(stagrForSense)
        }
        guard validKana.isEmpty == false else { return fallback }
        return kanaForms.first(where: { validKana.contains($0.text) })?.text ?? fallback
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
