import Foundation

// Configures node-cost weighting for Viterbi path scoring.
nonisolated struct SegmenterScoring {
    let baseCost: Int
    let lengthReward: Int
    let singleCharacterPenalty: Int
    let deinflectionPenalty: Int
    let dictionaryBonus: Int
    let unknownSegmentPenalty: Int
    let posGoodTransitionBonus: Int
    let posBadTransitionPenalty: Int

    static let `default` = SegmenterScoring(
        baseCost: 10,
        lengthReward: 3,
        singleCharacterPenalty: 3,
        deinflectionPenalty: 2,
        dictionaryBonus: 6,
        unknownSegmentPenalty: 40,
        posGoodTransitionBonus: -50,
        posBadTransitionPenalty: 150
    )

    // MARK: - Node-cost model (consumed by edgeCost, the node layer of the global path)
    //
    // A word's cost is its negative log probability, −ln P(word), in centi-nats, taken from the
    // frequency of the surface AS WRITTEN (see DictionaryStore.fetchFrequencyScoreBySurface). That
    // single quantity does every job the structural bonuses used to be hand-tuned for: every word
    // pays at least a few nats, so fewer/longer words win without a length reward; a rare word
    // costs more than a common one without a rarity penalty; and a kana string nobody writes as a
    // word (がそ for 画素) is unranked and therefore expensive, so が + そこ beats がそ + こ without a
    // denylist. Do not add per-surface or per-script special cases here — fix the frequency data.

    // frequencyScore is Zipf-like: log10 of occurrences per `zipfScaleExponent` decades of words,
    // so −ln P = (zipfScaleExponent − score) · ln 10. This is also the fixed overhead every word
    // pays, i.e. how strongly the path prefers fewer words. Fitted on training sentences and
    // confirmed on held-out ones (see scripts/segmentation-eval): below ~8.5 it stops
    // fixing errors and only trades merged units for split ones.
    static let zipfScaleExponent = 8.5

    // Nats charged per deinflection rule applied (LatticeEdge.inflectionSteps): P(this form | lemma)
    // is below 1, and without it a conjugated surface inherits its lemma's whole frequency however
    // contorted the chain — which is how junk spans like つ始める (問題|はい|つ始める) came out cheap.
    // Fitted with zipfScaleExponent; it peaks at 2–3, and past that it starts splitting genuine
    // conjugated forms.
    static let inflectionStepNats = 3.0

    // Score assumed for a dictionary word with no frequency rank at all: rarer than any ranked word.
    static let unrankedDictionaryScore = 1.0

    // Unknown (non-dictionary) text: a flat word cost plus a steep per-character cost, in nats, so
    // stranding a fragment is always worse than any parse that covers it with real words.
    static let unknownBaseNats = 12.0
    static let unknownPerCharacterNats = 6.0

    // Weight on the transition layer (SegmenterTransitionTable): cost = −weight · PMI(previous class,
    // next class). Fitted on training sentences, confirmed on held-out ones. Cut-through errors stop
    // falling at about 1.5; above it the only thing that grows is over-splitting.
    static let transitionWeight = 1.5

    // A single transition never moves a path by more than this many nats times the weight, so one
    // thinly attested pair cannot outvote the word costs. Lowered from 5.0: a bare-noun-after-よ
    // bigram (lyric line-breaks carry no punctuation, so a w:よ→n transition can be as sparse in
    // training as it is common in lyrics) was pricing that edge above the old clamp, letting a
    // competing lexical split (つたえ｜てよ) undercut the correct て-form＋よ analysis by a slim
    // margin — see つたえてよスターライト in SegmentationQualityTests. Re-measured at 3.0 against
    // held2k/kana2k/fresh5k: cut-through never regresses (kana2k improves, 276→269 straddles);
    // exact dips by <0.05pp on held2k/fresh5k, within noise. A 2026-09 "clamp is inert" finding
    // was under a 16-class transition table, superseded by the current ~1,100-class system.
    static let transitionClampNats = 3.0

    // Cost of a digit run (LatticeEdge from Segmenter.numberRunEdge), in nats — about what a common
    // word costs: low enough that ２ + 時間 beats ２時 + 間, high enough that １日 and ２人 stay words.
    static let numberNats = 6.0

    // True for ASCII and full-width latin letters.
    static func isLatinLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { ScriptClassifier.unknownGrouping(for: Character($0)) == "latin" }
    }

    // True for the characters a latin word run is made of: latin letters and digits.
    static func isLatinWordCharacter(_ character: Character) -> Bool {
        isLatinLetter(character) || isDigit(character)
    }

    // True for ASCII and full-width digits.
    static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) || (0xFF10...0xFF19).contains($0.value) }
    }

    // Trailing kana that signal "this surface ends with a grammatical particle/auxiliary fused
    // onto its stem" — checked at lattice-build time, not at every transition lookup.
    static let grammaticalEndingKana: Set<Character> = ["た", "だ", "て", "で", "よ"]

    // Node cost of one lattice edge: −ln P(surface) in centi-nats, independent of its neighbours.
    static func edgeCost(_ edge: LatticeEdge) -> Int {
        // Punctuation and whitespace are forced single-character edges every path must take.
        if isPunctuationSurface(edge.surface) { return 0 }

        // A bound character that path selection will fold into the preceding segment (see
        // LatticeEdge.isAbsorbedBoundCharacter) must not be priced as unknown text, or the path
        // contorts to avoid it (だ|めっ over だめ|っ). A small tsu that is NOT absorbed — one followed
        // by kana — keeps its full unknown cost, so もっとも|っ|と still loses to もっと|もっと.
        if edge.isAbsorbedBoundCharacter { return 0 }

        guard edge.isDictionaryMatch else {
            // A number is not unknown text: it costs what a common word costs, whatever its length.
            if edge.surface.allSatisfy(isDigit) { return Int((numberNats * 100).rounded()) }
            // A latin word (Segmenter.latinRunEdge) is one foreign word, not a string of unknown letters.
            if let first = edge.surface.first, isLatinLetter(first), edge.surface.allSatisfy(isLatinWordCharacter) { return Int((numberNats * 100).rounded()) }
            return Int(((unknownBaseNats + unknownPerCharacterNats * Double(edge.surface.count)) * 100).rounded())
        }

        return Int((wordNats(score: edge.frequencyScore, inflectionSteps: edge.inflectionSteps) * 100).rounded())
    }

    // −ln P of a dictionary word with this frequency score (0 = unranked), plus the inflection-step charge.
    static func wordNats(score: Double, inflectionSteps: Int) -> Double {
        let ranked = score > 0 ? score : unrankedDictionaryScore
        return (zipfScaleExponent - ranked) * log(10.0) + inflectionStepNats * Double(inflectionSteps)
    }

    // Detects punctuation-only single-character surfaces so they avoid strong lexical penalties.
    private static func isPunctuationSurface(_ surface: String) -> Bool {
        guard surface.count == 1 else { return false }
        for scalar in surface.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            return false
        }
        return true
    }
}
