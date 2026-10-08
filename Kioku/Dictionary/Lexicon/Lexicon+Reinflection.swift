import Foundation

// Re-inflects other words the way a sentence inflects one, so a quiz's wrong options share the
// blank's form (食べた → 見た, 寝た) instead of standing out as dictionary forms.
extension Lexicon {
    // Up to `limit` candidates inflected along the rule path that takes `lemma` to `surface`, in
    // candidate order. A candidate qualifies only when it shares one of the lemma's exact JMdict
    // conjugation tags and the result deinflects back to it. Empty when `surface` is not an
    // inflection of `lemma`.
    func inflectLike(
        surface: String,
        lemma: String,
        candidates: [(text: String, posTags: [String])],
        limit: Int
    ) -> [String] {
        guard limit > 0, surface != lemma,
              let transitions = deinflector.bestTransitions(for: surface, targetLemma: lemma),
              transitions.isEmpty == false else { return [] }
        let lemmaTags = conjugationTags(ofLemma: lemma)
        guard lemmaTags.isEmpty == false else { return [] }

        var results: [String] = []
        var seen: Set<String> = [surface]
        for candidate in candidates where candidate.text != lemma {
            guard ConjugationClass.conjugatingTags(in: candidate.posTags).isDisjoint(with: lemmaTags) == false,
                  let inflected = applySurfaceTransitions(to: candidate.text, transitions: transitions),
                  seen.contains(inflected) == false,
                  deinflector.deinflectionPaths(for: inflected)[candidate.text] != nil else { continue }
            seen.insert(inflected)
            results.append(inflected)
            if results.count >= limit { break }
        }
        return results
    }

    // The exact conjugating JMdict tags of the entries that spell `lemma` verbatim.
    private func conjugationTags(ofLemma lemma: String) -> Set<String> {
        let posTags = lookupEntries(for: lemma)
            .filter { entry in
                entry.kanjiForms.contains { $0.text == lemma } || entry.kanaForms.contains { $0.text == lemma }
            }
            .flatMap { $0.senses.compactMap(\.pos) }
            .flatMap { $0.components(separatedBy: ",") }
        return ConjugationClass.conjugatingTags(in: posTags)
    }
}
