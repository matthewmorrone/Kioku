import Foundation

// The structural relationship a related entry bears to the saved word. Pure data — the
// human-readable label lives on RelatedWordsOrganizer so this stays a cases-only enum.
nonisolated public enum StructuralRelation: Equatable, Sendable {
    // The related entry is the transitive partner of an intransitive saved verb (出る → 出す).
    case transitiveCounterpart
    // The related entry is the intransitive partner of a transitive saved verb (上げる → 上がる).
    case intransitiveCounterpart
    // The related entry shares the saved word's exact kanji skeleton but isn't a
    // transitivity counterpart — a same-stem morphological variant (上げる → 上げ).
    case sameStemForm
}

// One kanji-family related entry tagged with the structural relationship it bears to the
// saved word. Pure data so it may be grouped with the relation enum in this file.
nonisolated public struct StructuralRelatedEntry: Equatable, Sendable {
    public let entry: DictionaryEntry
    public let relation: StructuralRelation

    public init(entry: DictionaryEntry, relation: StructuralRelation) {
        self.entry = entry
        self.relation = relation
    }
}

// Splits the frequency-ordered kanji-family "related words" of a saved entry into a tightly
// structural group (transitive/intransitive verb counterparts and same-stem morphological
// variants — the words a learner most wants pinned to the top) and the looser remainder that
// merely shares the headword's primary kanji. Pure and synchronous so it can be unit-tested
// without a database.
nonisolated public enum RelatedWordsOrganizer {
    // Partitions `related` against `saved`. Within each returned group the caller's input
    // (frequency) order is preserved; transitivity counterparts are emitted ahead of other
    // same-stem forms so a verb's intransitive/transitive pair sits at the very top.
    public static func partition(
        saved: DictionaryEntry,
        related: [DictionaryEntry]
    ) -> (structural: [StructuralRelatedEntry], others: [DictionaryEntry]) {
        let savedSkeleton = kanjiSkeleton(of: saved)
        // Without a kanji skeleton (pure-kana entries) there is no structural stem to match on,
        // so everything stays in the general remainder.
        guard savedSkeleton.isEmpty == false else { return ([], related) }

        let savedPOS = posTags(of: saved)
        let savedTransitive = savedPOS.contains("vt")
        let savedIntransitive = savedPOS.contains("vi")

        var counterparts: [StructuralRelatedEntry] = []
        var sameStem: [StructuralRelatedEntry] = []
        var others: [DictionaryEntry] = []

        for entry in related {
            let skeleton = kanjiSkeleton(of: entry)
            guard skeleton.isEmpty == false, skeleton == savedSkeleton else {
                others.append(entry)
                continue
            }
            let pos = posTags(of: entry)
            if savedTransitive && pos.contains("vi") {
                counterparts.append(StructuralRelatedEntry(entry: entry, relation: .intransitiveCounterpart))
            } else if savedIntransitive && pos.contains("vt") {
                counterparts.append(StructuralRelatedEntry(entry: entry, relation: .transitiveCounterpart))
            } else {
                sameStem.append(StructuralRelatedEntry(entry: entry, relation: .sameStemForm))
            }
        }

        return (counterparts + sameStem, others)
    }

    // Short accent-colored badge text describing the relationship, shown on the structural rows.
    public static func label(for relation: StructuralRelation) -> String {
        switch relation {
        case .transitiveCounterpart: return "Transitive pair"
        case .intransitiveCounterpart: return "Intransitive pair"
        case .sameStemForm: return "Related form"
        }
    }

    // The entry's kanji-only skeleton: its preferred kanji headword with all kana (okurigana)
    // stripped. Transitive/intransitive pairs share an identical skeleton and differ only in
    // okurigana (上げる/上がる → 上, 待ち合わせる/待ち合わす → 待合), which makes skeleton equality a
    // reliable, data-free way to recognize a stem pair.
    static func kanjiSkeleton(of entry: DictionaryEntry) -> String {
        let source = entry.firstEverydayKanji?.text ?? entry.kanjiForms.first?.text ?? ""
        return String(source.filter { $0.unicodeScalars.allSatisfy(ScriptClassifier.isKanjiScalar) })
    }

    // The deduplicated set of JMdict part-of-speech tags across every sense (e.g. "vt", "vi",
    // "v5r"). Used to detect transitivity.
    static func posTags(of entry: DictionaryEntry) -> Set<String> {
        var tags: Set<String> = []
        for sense in entry.senses {
            guard let pos = sense.pos else { continue }
            for tag in pos.components(separatedBy: ",") {
                let trimmed = tag.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty == false { tags.insert(trimmed) }
            }
        }
        return tags
    }
}
