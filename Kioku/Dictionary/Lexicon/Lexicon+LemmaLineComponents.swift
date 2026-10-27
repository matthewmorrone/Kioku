import Foundation

extension Lexicon {
    // Each word a lemma line names (起こる + そう) with its meaning, for the lookup sheet's rows, so a
    // helper word gets defined beside the lemma instead of only named. nil for a single-word line.
    // A helper word is taken in its auxiliary, suffix or particle sense where it has one: そう's top
    // entry is the adverb "in that way", but the そう folded into 起こりそう is the auxiliary
    // "appearing that; seeming that". JMdict's own part-of-speech tags decide, not a word list.
    // Each word also carries the entry its meaning came from, so the word detail screen can open it.
    public func lemmaLineComponents(_ lemmaLine: String) -> [(lemma: String, gloss: String?, entry: DictionaryEntry?)]? {
        let parts = lemmaLine.components(separatedBy: " + ")
        guard parts.count > 1 else { return nil }
        return parts.enumerated().map { index, part in
            let entries = lookupEntries(for: part)
            let helperEntry = index > 0 ? entries.first(where: { entry in entry.senses.contains { Self.isHelperPOS($0.pos) } }) : nil
            let entry = helperEntry ?? entries.first
            let senses = entry?.senses.filter { $0.glosses.isEmpty == false } ?? []
            let sense = (helperEntry != nil ? senses.first(where: { Self.isHelperPOS($0.pos) }) : nil) ?? senses.first
            return (lemma: part, gloss: sense?.glosses.prefix(3).joined(separator: "; "), entry: entry)
        }
    }

    // Whether a lemma line is one content word followed only by grammar (起こる + そう, 食べる + させる +
    // られる): every word after the first has an auxiliary, suffix or particle sense. Such a form is
    // one word's inflection, so it has a head to save and open. A line whose later words are full
    // words (歌う + 続ける + ゆく where none is tagged, 本 + の + 虫) has no single head.
    public func lemmaLineIsHeadWithHelpers(_ lemmaLine: String) -> Bool {
        let parts = lemmaLine.components(separatedBy: " + ")
        guard parts.count > 1 else { return false }
        return parts.dropFirst().allSatisfy { part in
            lookupEntries(for: part).contains { entry in entry.senses.contains { Self.isHelperPOS($0.pos) } }
        }
    }

    // Whether a sense's comma-joined JMdict pos tags mark it as grammar attached to another word:
    // an auxiliary (aux, aux-v, aux-adj), a suffix (suf, n-suf, v-suf) or a particle (prt).
    private static func isHelperPOS(_ pos: String?) -> Bool {
        guard let pos else { return false }
        return pos.components(separatedBy: ",").contains { tag in
            tag.hasPrefix("aux") || tag.hasSuffix("suf") || tag == "prt"
        }
    }
}
