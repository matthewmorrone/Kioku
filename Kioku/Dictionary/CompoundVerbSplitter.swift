import Foundation

// Names the two verbs inside a compound verb — 生きてゆく → 生きる + ゆく, 思い出す → 思う + 出す,
// さがしつづけた → さがす + つづける — for the lookup sheet's dictionary-form subtitle. Conjugated
// compounds collapse to one lattice edge via Deinflector's compoundVerbRecoveryForms and lexicalized
// ones are their own headwords, so neither shows its parts on its own; the surface's lattice still
// holds the natural head + auxiliary split, and DerivationAnalyzer's compound-verb rule confirms it.
// Shared with scripts/segmentation-eval's `compounds` mode so the split is measured as shipped.
nonisolated enum CompoundVerbSplitter {

    // Returns the base + auxiliary lemmas for `surface`, or nil when it isn't a compound verb.
    // `edges` is the surface's lattice (or the selection's slice of the note's lattice); `posTags`
    // looks a lemma up and returns its JMdict POS tags.
    static func parts(
        surface: String,
        edges: [LatticeEdge],
        segmenter: any TextSegmenting,
        posTags: @escaping (String) -> [String]
    ) -> DerivationAnalyzer.CompoundVerbParts? {
        // Only a verb has compound-verb parts: a noun or adverb that happens to split into verb
        // pieces (いきいき → いき + いき, リサイクル) is not one. A suru-noun counts as a noun here.
        let surfaceLemmas = [surface] + segmenter.lemmaCandidates(for: surface)
        guard surfaceLemmas.contains(where: { conjugatingVerbClass(posTags($0)) != nil }) else { return nil }

        guard let split = LatticeEdge.auxiliaryVerbSplit(
                  from: edges,
                  auxiliaries: DerivationAnalyzer.auxiliaryVerbs,
                  lemmaResolver: { tailLemma(for: $0, segmenter: segmenter, posTags: posTags) },
                  headValidator: { headLemma(for: $0, segmenter: segmenter, posTags: posTags) != nil }
              ),
              let rawHead = split.first, let rawTail = split.last,
              let head = headLemma(for: rawHead, segmenter: segmenter, posTags: posTags),
              let tail = tailLemma(for: rawTail, segmenter: segmenter, posTags: posTags) else { return nil }
        return DerivationAnalyzer.compoundVerb(components: [head, tail], baseResolver: posTags, glossResolver: nil)?
            .compoundVerbParts
    }

    // The verb whose te-form (生きて, 付いて) or masu-stem (思い, 抜け, 寝) `head` is. Checked by
    // conjugating each candidate forward rather than trusting the candidate order: 抜け also
    // deinflects to 抜く (as its potential/imperative), but only 抜ける has 抜け as its stem — so the
    // match is against the Polite row itself, never the potential polite 抜けます of 抜く. A te-form
    // reading wins over a stem one (付いて is 付く's te-form, not the stem of the colloquial 付いてる).
    // A one-kana head is refused — ふ + くれる, で + きる are coincidences of kana, not compounds.
    private static func headLemma(for head: String, segmenter: any TextSegmenting, posTags: (String) -> [String]) -> String? {
        if head.count < 2, head.unicodeScalars.contains(where: ScriptClassifier.isKanjiScalar) == false { return nil }
        let candidates = segmenter.lemmaCandidates(for: head)
        let groupsByCandidate = candidates.map { candidate -> [ConjugationGroup] in
            guard let verbClass = VerbConjugator.detectVerbClass(fromJMDictPosTags: posTags(candidate)) else { return [] }
            return VerbConjugator.conjugationGroups(for: candidate, verbClass: verbClass)
        }
        let rows: (Int, String) -> [String] = { index, groupName in
            groupsByCandidate[index].first(where: { $0.name == groupName })?.rows.map(\.surface) ?? []
        }
        if head.hasSuffix("て") || head.hasSuffix("で"),
           let index = candidates.indices.first(where: { rows($0, "Te-form").contains(head) }) {
            return candidates[index]
        }
        return candidates.indices.first(where: { rows($0, "Polite").first == head + "ます" }).map { candidates[$0] }
    }

    // The tail's own dictionary form when it is already one (込める stays 込める, not the 込む it
    // also deinflects to); otherwise its lemma, preferring an auxiliary reading (ゆこう → ゆく, not
    // its unrelated headword).
    private static func tailLemma(for tail: String, segmenter: any TextSegmenting, posTags: (String) -> [String]) -> String? {
        if conjugatingVerbClass(posTags(tail)) != nil { return tail }
        return segmenter.preferredLemma(for: tail, preferring: DerivationAnalyzer.auxiliaryVerbs)
    }

    // The verb class for POS tags that make a word conjugate as a verb in its own right: ichidan,
    // godan or kuru. Suru-nouns (vs) are nouns that take する, not verbs.
    private static func conjugatingVerbClass(_ tags: [String]) -> VerbClass? {
        let verbClass = VerbConjugator.detectVerbClass(fromJMDictPosTags: tags.filter { $0.hasPrefix("vs") == false })
        return verbClass
    }
}
