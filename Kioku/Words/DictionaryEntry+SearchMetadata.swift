import Foundation

// Search-specific display and filtering helpers derived from the materialized dictionary entry.
extension DictionaryEntry {
    // Returns the preferred headword shown in list rows and used for alphabetical sort.
    var primarySearchSurface: String {
        kanjiForms.first?.text ?? kanaForms.first?.text ?? matchedSurface
    }

    // Returns the preferred reading shown beside the headword when it differs from the surface.
    var primarySearchReading: String? {
        guard kanjiForms.isEmpty == false else { return nil }
        return kanaForms.first?.text
    }

    // Returns the first gloss string used by the compact search-results row.
    var primarySearchGloss: String {
        senses.first?.glosses.first ?? ""
    }

    // Returns expanded part-of-speech labels for search filtering.
    var searchPartOfSpeechLabels: [String] {
        var labels: [String] = []
        var seen = Set<String>()

        for sense in senses {
            guard let pos = sense.pos, pos.isEmpty == false else { continue }
            for rawLabel in JMdictTagExpander.expandAll(pos).split(separator: ",") {
                let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty == false, seen.insert(label).inserted else { continue }
                labels.append(label)
            }
        }

        return labels
    }

    // JMdict ke_inf tags marking kanji forms that exist in the data but are essentially never
    // used in modern writing: rare, outdated, irregular, or search-only. We treat these
    // collectively as "non-everyday" and suppress them in display headers.
    private static let nonEverydayKanjiTags: Set<String> = ["rK", "oK", "iK", "sK"]

    // Returns true when the given kanji-form info string carries any non-everyday tag.
    static func kanjiFormIsNonEveryday(info: String?) -> Bool {
        guard let info, info.isEmpty == false else { return false }
        let tags = info.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return tags.contains { nonEverydayKanjiTags.contains(String($0)) }
    }

    // First kanji form whose ke_inf isn't tagged rare/outdated/irregular/search-only. Used by
    // header rendering so a learner-facing display doesn't surface 此処/茲/爰 for ここ.
    var firstEverydayKanji: KanjiForm? {
        kanjiForms.first { !DictionaryEntry.kanjiFormIsNonEveryday(info: $0.info) }
    }

    // True when the entry has no kanji a learner would actually encounter — either it has none
    // at all or every kanji form is tagged rare/outdated/irregular/search-only.
    var hasNoEverydayKanji: Bool { firstEverydayKanji == nil }

    // True when every sense carries the JMdict `uk` (usually-kana) misc tag.
    var allSensesUsuallyKana: Bool {
        senses.isEmpty == false && senses.allSatisfy { ($0.misc ?? "").contains("uk") }
    }

    // Approximates common-word status from JMdict priority tags and the frequency datasets.
    var isCommonSearchEntry: Bool {
        let priorities = (kanjiForms.compactMap(\.priority) + kanaForms.compactMap(\.priority))
            .joined(separator: ",")
            .lowercased()

        if priorities.contains("news1")
            || priorities.contains("ichi1")
            || priorities.contains("spec1")
            || priorities.contains("gai1") {
            return true
        }

        if let jpdbRank, jpdbRank <= 20_000 {
            return true
        }

        if let wordfreqZipf, wordfreqZipf >= 4.5 {
            return true
        }

        return false
    }
}
