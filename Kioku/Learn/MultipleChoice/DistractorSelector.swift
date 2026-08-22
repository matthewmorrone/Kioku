import Foundation

// The coarse grammatical class of a word, collapsed from its JMdict part-of-speech tags. Only as
// fine as multiple choice needs: options are convincing when they read as the same kind of word as
// the answer ("to eat" against three other verbs), and no finer distinction than that changes
// whether a distractor is plausible.
nonisolated enum WordClass: String, Sendable {
    case verb
    case adjective
    case adverb
    case noun
    case other

    // Collapses a sense's JMdict pos codes. Order matters: JMdict tags an adjectival noun both
    // `adj-na` and `n`, and a suru-verb noun both `vs` and `n`, so the more specific class has to
    // win before the noun catch-all sees the tag.
    static func from(posTags: some Sequence<String>) -> WordClass {
        var sawVerb = false
        var sawAdverb = false
        var sawNoun = false
        for tag in posTags {
            // `adj-i`, `adj-na`, `adj-no`, `adj-ix`, … — all adjectives, and the strongest signal.
            if tag.hasPrefix("adj") { return .adjective }
            // `adv`, `adv-to`. Checked before the verb prefix only because neither overlaps.
            if tag.hasPrefix("adv") { sawAdverb = true; continue }
            // `v1`, `v5r`, `vs-i`, `vk`, `vt`, `vi`, … Every verb code starts with v, and no
            // non-verb code does.
            if tag.hasPrefix("v") { sawVerb = true; continue }
            // `n`, `n-adv`, `n-suf`, `pn`, … the fallback when nothing more specific applies.
            if tag == "pn" || tag == "n" || tag.hasPrefix("n-") { sawNoun = true }
        }
        if sawVerb { return .verb }
        if sawAdverb { return .adverb }
        if sawNoun { return .noun }
        return .other
    }
}

// One option that could stand in as a wrong answer, paired with what kind of word it is.
nonisolated struct DistractorCandidate: Equatable, Sendable {
    let text: String
    let wordClass: WordClass
}

// Picks which wrong answers a multiple-choice question offers. Split out from the view because the
// rules are the whole substance of a fair question and are worth testing directly.
//
// Two things make an option set unfair, and both are about the options rather than the answer:
// a lone verb among three nouns is findable without knowing the word, and so is the lone option
// whose okurigana matches the prompt's (asked 食べる, only one choice ends in べる). So candidates
// are ranked by how well they imitate the answer — same word class, same trailing kana — rather
// than filtered, which keeps a question at four options when the pool can't fully oblige.
nonisolated enum DistractorSelector {
    // How much trailing kana two words end with in common — べる for たべる and かべる, "" for
    // たべる and 本. The measure of "same form" that ranking uses.
    static func sharedTrailingKanaLength(_ lhs: String, _ rhs: String) -> Int {
        var shared = 0
        for (left, right) in zip(lhs.reversed(), rhs.reversed()) {
            guard left == right else { break }
            guard left.unicodeScalars.allSatisfy(ScriptClassifier.isKanaScalar) else { break }
            shared += 1
        }
        return shared
    }

    // Chooses up to `count` distractors, best imitators first. `candidates` is consumed in the
    // order given (shuffle before calling to keep option sets varied); ties preserve that order, so
    // the pick stays random among equally good candidates rather than favouring whatever the
    // dictionary happened to return first.
    //
    // `prompt` matters only for how much okurigana the question already gives away: when the prompt
    // shares no trailing kana with the answer (any question answered in English, or 本 → book),
    // matching trailing kana isn't a tell and only word class is scored.
    static func choose(
        from candidates: [DistractorCandidate],
        answer: DistractorCandidate,
        prompt: String,
        count: Int
    ) -> [String] {
        guard count > 0 else { return [] }
        let exposedOkurigana = sharedTrailingKanaLength(prompt, answer.text)
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let leftScore = score(lhs.element, answer: answer, exposedOkurigana: exposedOkurigana)
            let rightScore = score(rhs.element, answer: answer, exposedOkurigana: exposedOkurigana)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.offset < rhs.offset
        }
        return ranked.prefix(count).map { $0.element.text }
    }

    // How convincing one candidate is against this answer. Trailing kana outweighs word class: a
    // mismatched class makes an option look odd, but the only option sharing the prompt's
    // okurigana can simply be read off without knowing the word at all.
    private static func score(
        _ candidate: DistractorCandidate,
        answer: DistractorCandidate,
        exposedOkurigana: Int
    ) -> Int {
        var score = candidate.wordClass == answer.wordClass ? 1 : 0
        guard exposedOkurigana > 0 else { return score }
        let shared = sharedTrailingKanaLength(candidate.text, answer.text)
        if shared >= exposedOkurigana {
            score += 4      // fully matches the form the prompt already reveals
        } else if shared > 0 {
            score += 2      // partly matches — still better than an ending the prompt rules out
        }
        return score
    }
}
