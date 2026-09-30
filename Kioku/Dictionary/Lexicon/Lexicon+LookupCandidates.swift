import Foundation

// Every dictionary word a surface can be, for the lookup sheet's list of possibilities. A kana
// form is often several words at once — いった is the past of 言う, 行く and godan 要る — and the
// kana is the same for all of them, so the reading arrows cannot tell them apart.
nonisolated extension Lexicon {
    // How many possibilities the sheet lists; past this the rows are rare homographs.
    static let maxLookupCandidates = 6

    // The words `surface` can be, best first. The first row is the engine's own pick (its top lemma's
    // most frequent entry); after it, each other lemma's most frequent entry in lemma order, then the
    // remaining ranked entries by frequency. An entry only counts when it conjugates the way the
    // chain reaching it claims: いった reaches いる by a godan rule, so 要る is listed and 居る is not.
    // The surface's own headwords are always possibilities too, even when the engine reads the form
    // as a conjugation: きた is 来る's past and also 北.
    func lookupCandidates(surface: String) -> [LookupCandidate] {
        var (lemmas, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        if lemmas.contains(where: { $0.lemma == surface }) == false {
            lemmas.append((lemma: surface, depth: 0))
        }
        var leaders: [LookupCandidate] = []
        var others: [LookupCandidate] = []
        var seenEntryIDs = Set<Int64>()
        for (lemma, _) in lemmas {
            let grammars = deinflector.endingGrammars(from: pathsByLemma, targetLemma: lemma)
            let entries = lookupEntries(for: lemma)
                .filter { entry in
                    grammars.isEmpty
                        || ConjugationClass.grammars(forPOSStrings: entry.senses.compactMap(\.pos)).isDisjoint(with: grammars) == false
                }
                .filter { seenEntryIDs.insert($0.entryId).inserted }
                .sorted { ($0.frequencyRank ?? Int.max) < ($1.frequencyRank ?? Int.max) }
            for (index, entry) in entries.enumerated() {
                let candidate = LookupCandidate(
                    lemma: lemma,
                    headword: entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? lemma,
                    reading: entry.kanaForms.first?.text ?? lemma,
                    entry: entry
                )
                if index == 0 {
                    leaders.append(candidate)
                } else if entry.frequencyRank != nil {
                    others.append(candidate)
                }
            }
        }
        others.sort { ($0.entry.frequencyRank ?? Int.max) < ($1.entry.frequencyRank ?? Int.max) }
        return Array((leaders + others).prefix(Self.maxLookupCandidates))
    }
}
