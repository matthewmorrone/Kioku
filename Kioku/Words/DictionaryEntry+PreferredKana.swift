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
    func preferredKana(
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
}
