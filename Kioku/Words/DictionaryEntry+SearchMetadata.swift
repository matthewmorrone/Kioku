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
