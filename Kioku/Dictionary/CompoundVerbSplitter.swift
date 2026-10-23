import Foundation

// Names the two verbs inside a compound verb — 生きてゆく → 生きる + ゆく, 思い出す → 思う + 出す,
// さがしつづけた → さがす + つづける, 巡り会う → 巡る + 会う — for the lookup sheet's dictionary-form
// subtitle and the word detail header. Conjugated
// compounds collapse to one lattice edge via Deinflector's compoundVerbRecoveryForms and lexicalized
// ones are their own headwords, so neither shows its parts on its own; the surface's lattice still
// holds the natural head + auxiliary split, and DerivationAnalyzer's compound-verb rule confirms it.
// Shared with scripts/segmentation-eval's `compounds` mode so the split is measured as shipped.
enum CompoundVerbSplitter {

    // Returns the base + auxiliary lemmas for `surface`, or nil when it isn't a compound verb.
    // `edges` is the surface's lattice (or the selection's slice of the note's lattice); `senseTags`
    // looks a lemma up and returns the JMdict POS tags of each of its senses.
    static func parts(
        surface: String,
        edges: [LatticeEdge],
        segmenter: any TextSegmenting,
        senseTags: @escaping (String) -> [[String]]
    ) -> DerivationAnalyzer.CompoundVerbParts? {
        let posTags: (String) -> [String] = { senseTags($0).flatMap { $0 } }
        // Only a verb has compound-verb parts: a noun or adverb that happens to split into verb
        // pieces (いきいき → いき + いき, リサイクル) is not one. A suru-noun counts as a noun here.
        let surfaceLemmas = [surface] + segmenter.lemmaCandidates(for: surface)
        guard surfaceLemmas.contains(where: { conjugatingVerbClass(posTags($0)) != nil }) else { return nil }

        if let split = LatticeEdge.auxiliaryVerbSplit(
               from: edges,
               auxiliaries: DerivationAnalyzer.auxiliaryVerbs,
               lemmaResolver: { tailLemma(for: $0, segmenter: segmenter, posTags: posTags) },
               headValidator: { headLemma(for: $0, segmenter: segmenter, posTags: posTags) != nil }
           ),
           let rawHead = split.first, let rawTail = split.last,
           let head = headLemma(for: rawHead, segmenter: segmenter, posTags: posTags),
           let tail = tailLemma(for: rawTail, segmenter: segmenter, posTags: posTags),
           let parts = DerivationAnalyzer.compoundVerb(components: [head, tail], baseResolver: posTags, glossResolver: nil)?
               .compoundVerbParts {
            return parts
        }
        // A verb headword is split as written (打ちひしがれる is not 打ちひしぐ's passive); only an
        // inflected surface goes through its lemmas.
        let verbs = conjugatingVerbClass(posTags(surface)) != nil ? [surface] : surfaceLemmas
        return verbs.lazy.compactMap { lexicalParts(verb: $0, segmenter: segmenter, senseTags: senseTags) }.first
    }

    // Names the two full verbs of a lexical compound verb — 巡り会う → 巡る + 会う, 取り扱う → 取る + 扱う —
    // whose second verb keeps its own meaning rather than acting as an auxiliary, so it is on no list:
    // `verb` must be a verb headword that splits into another verb's masu-stem plus a verb headword.
    // The shortest such stem wins. Nil when `verb` is no verb or has no such split. `auxiliary` in the
    // result holds the second verb, with no auxiliary gloss.
    static func lexicalParts(
        verb: String,
        segmenter: any TextSegmenting,
        senseTags: (String) -> [[String]]
    ) -> DerivationAnalyzer.CompoundVerbParts? {
        // Every tag of every sense, for the checks that only ask whether some sense is a verb.
        func posTags(_ lemma: String) -> [String] { senseTags(lemma).flatMap { $0 } }
        guard conjugatingVerbClass(posTags(verb)) != nil else { return nil }
        let characters = Array(verb)
        // The second verb is at least two characters (会う, 出る): a one-kana tail is a verb ending.
        guard characters.count >= 3 else { return nil }
        for cut in 1...(characters.count - 2) {
            let tail = String(characters[cut...])
            // The second verb needs a sense of its own as a verb: one only ever a suffix or auxiliary
            // (がる in 欲しがる) is grammar. 上げる also has such senses, but its plain ones admit it.
            guard senseTags(tail).contains(where: { tags in
                tags.contains("suf") == false && tags.contains("aux-v") == false && conjugatingVerbClass(tags) != nil
            }) else { continue }
            let head = String(characters[..<cut])
            guard isStemHeadAdmissible(head), let base = masuStemLemma(for: head, segmenter: segmenter, posTags: posTags) else { continue }
            return DerivationAnalyzer.CompoundVerbParts(base: base, auxiliary: tail, baseGloss: nil, auxiliaryGloss: nil)
        }
        return nil
    }

    // The verb whose te-form (生きて, 付いて) or masu-stem (思い, 抜け, 寝) `head` is. Checked by
    // conjugating each candidate forward rather than trusting the candidate order: 抜け also
    // deinflects to 抜く (as its potential/imperative), but only 抜ける has 抜け as its stem — so the
    // match is against the Polite row itself, never the potential polite 抜けます of 抜く. A te-form
    // reading wins over a stem one (付いて is 付く's te-form, not the stem of the colloquial 付いてる).
    private static func headLemma(for head: String, segmenter: any TextSegmenting, posTags: (String) -> [String]) -> String? {
        guard isStemHeadAdmissible(head) else { return nil }
        if head.hasSuffix("て") || head.hasSuffix("で"),
           let teLemma = segmenter.lemmaCandidates(for: head).first(where: { candidate in
               conjugationRows(of: candidate, group: "Te-form", posTags: posTags).contains(head)
           }) {
            return teLemma
        }
        return masuStemLemma(for: head, segmenter: segmenter, posTags: posTags)
    }

    // The verb whose masu-stem `head` is (思い → 思う, 巡り → 巡る), matched on its Polite row so a
    // potential or imperative reading of the same kana (抜け as 抜く's) never counts.
    private static func masuStemLemma(for head: String, segmenter: any TextSegmenting, posTags: (String) -> [String]) -> String? {
        segmenter.lemmaCandidates(for: head).first { candidate in
            conjugationRows(of: candidate, group: "Polite", posTags: posTags).first == head + "ます"
        }
    }

    // The surfaces of one conjugation group of `verb`, or none when it has no verb entry.
    private static func conjugationRows(of verb: String, group: String, posTags: (String) -> [String]) -> [String] {
        guard let verbClass = VerbConjugator.detectVerbClass(fromJMDictPosTags: posTags(verb)) else { return [] }
        return VerbConjugator.conjugationGroups(for: verb, verbClass: verbClass)
            .first(where: { $0.name == group })?.rows.map(\.surface) ?? []
    }

    // A one-kana head is refused — ふ + くれる, で + きる are coincidences of kana, not compounds.
    private static func isStemHeadAdmissible(_ head: String) -> Bool {
        head.count >= 2 || head.unicodeScalars.contains(where: ScriptClassifier.isKanjiScalar)
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
