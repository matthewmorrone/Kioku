import Foundation

// Picks the default sense to spotlight on a flashcard for a freshly saved word.
// JMdict orders senses by listing position, not commonness, so falling back to senses[0]
// often surfaces archaic / obscure / rare meanings before the everyday one. This filter
// skips senses tagged with "low-priority" misc flags and returns the first remaining sense's
// id. If every sense is tagged, the entry's first sense is used as a last-resort default.
nonisolated enum DefaultSenseSelection {
    private static let lowPriorityMiscTags: Set<String> = ["arch", "obs", "obsc", "rare", "dated"]

    // Returns one sense id wrapped in an array so the caller can drop it straight into
    // SavedWord.selectedSenseIDs. Returns [] when the entry has no senses.
    static func defaultSelectedSenseIDs(for entry: DictionaryEntry) -> [Int64] {
        guard let firstSense = entry.senses.first else { return [] }
        let preferred = entry.senses.first { sense in
            let tags = miscTags(sense.misc)
            return tags.isDisjoint(with: lowPriorityMiscTags)
        }
        return [(preferred ?? firstSense).senseID]
    }

    // True when every sense of the entry is tagged archaic/obsolete/rare — i.e. the entry has no
    // everyday meaning. The word detail reading switcher uses this to drop fringe homograph
    // readings (e.g. the archaic うだく reading of 抱く) unless the user opts into archaic readings.
    // An entry with no senses is treated as non-archaic so it is never silently hidden.
    static func isEntirelyLowPriority(_ entry: DictionaryEntry) -> Bool {
        guard entry.senses.isEmpty == false else { return false }
        return entry.senses.allSatisfy { sense in
            miscTags(sense.misc).isDisjoint(with: lowPriorityMiscTags) == false
        }
    }

    // Splits a JMdict misc string ("arch,uk,col") into a normalized lowercase set.
    private static func miscTags(_ misc: String?) -> Set<String> {
        guard let misc, misc.isEmpty == false else { return [] }
        return Set(
            misc.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { $0.isEmpty == false }
        )
    }
}
