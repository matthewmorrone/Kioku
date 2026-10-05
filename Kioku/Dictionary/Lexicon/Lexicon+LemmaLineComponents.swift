import Foundation

extension Lexicon {
    // Each word a lemma line names (起こる + そう) with its meaning, for the lookup sheet's rows, so a
    // helper word gets defined beside the lemma instead of only named. nil for a single-word line.
    // A helper word is taken in its auxiliary, suffix or particle sense where it has one: そう's top
    // entry is the adverb "in that way", but the そう folded into 起こりそう is the auxiliary
    // "appearing that; seeming that". JMdict's own part-of-speech tags decide, not a word list.
    public func lemmaLineComponents(_ lemmaLine: String) -> [(lemma: String, gloss: String?)]? {
        let parts = lemmaLine.components(separatedBy: " + ")
        guard parts.count > 1 else { return nil }
        return parts.enumerated().map { index, part in
            let entries = lookupEntries(for: part)
            let senses = entries.flatMap(\.senses).filter { $0.glosses.isEmpty == false }
            let helperSense = index > 0 ? senses.first(where: { Self.isHelperPOS($0.pos) }) : nil
            let sense = helperSense ?? senses.first
            return (lemma: part, gloss: sense?.glosses.prefix(3).joined(separator: "; "))
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
