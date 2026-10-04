import Foundation

nonisolated extension FuriganaResolver {
    // The reading of an inflected word's kanji when inflecting changes the stem's own sound, as it
    // does for 来る: 来て is きて, 来ない こない, 来よう こよう. Cropping the dictionary form's
    // reading (くる → く) is right for every regular verb but wrong for these, so the inflected
    // reading comes from the deinflection rules, which list the irregular forms in kana (きて → くる).
    //
    // Candidate stems are the dictionary form's own (く) and every stem from rules that rewrite the
    // whole dictionary form (kanaOut くる for 来る): irregular forms are listed whole, while a rule
    // ending in くる must not touch 送る (おくる). A regular verb has only its own stem and keeps
    // the usual crop. Each candidate is checked by attaching the
    // surface's okurigana (こなかった for 来なかった) and deinflecting that kana back: only stems that
    // reach the dictionary form's reading count. Ties go to the stem from the rule that rewrote
    // more (きて over くて, which a generic ichidan rule also takes back to くる). Nil when nothing
    // but the dictionary form's own stem fits, so the caller's crop stands.
    func inflectedStemReading(surface: String, lemma: String, lemmaReading: String) -> String? {
        guard surface != lemma,
              let deinflector = (segmenter as? Segmenter)?.deinflector,
              let surfaceKanji = surface.lastIndex(where: { ScriptClassifier.containsKanji(String($0)) }),
              let lemmaKanji = lemma.lastIndex(where: { ScriptClassifier.containsKanji(String($0)) })
        else { return nil }
        let surfaceTail = String(surface[surface.index(after: surfaceKanji)...])
        let lemmaTail = String(lemma[lemma.index(after: lemmaKanji)...])
        let stemLength = lemmaReading.count - lemmaTail.count
        guard surfaceTail.isEmpty == false, stemLength > 0, lemmaReading.hasSuffix(lemmaTail) else { return nil }

        let ownStem = String(lemmaReading.prefix(stemLength))
        var specificityByStem: [String: Int] = [ownStem: lemmaTail.count]
        for (_, rule) in deinflector.labeledRulesForExpansion()
        where rule.kanaOut == lemmaReading && rule.kanaOut.count > lemmaTail.count {
            let inflected = String(lemmaReading.dropLast(rule.kanaOut.count)) + rule.kanaIn
            guard inflected.count > stemLength else { continue }
            let stem = String(inflected.prefix(stemLength))
            // A rule that leaves the stem as it is (くりゃ, くれば) is no evidence of a change.
            guard stem != ownStem else { continue }
            specificityByStem[stem] = max(specificityByStem[stem] ?? 0, rule.kanaOut.count)
        }
        guard specificityByStem.count > 1 else { return nil }

        let verified = specificityByStem.filter { stem, _ in
            deinflector.deinflectionPaths(for: stem + surfaceTail)[lemmaReading]?.isEmpty == false
        }
        guard let best = verified.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              best.key != ownStem else { return nil }
        return best.key
    }
}
