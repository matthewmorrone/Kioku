import Foundation

// Lemma resolution: mapping a surface (possibly inflected, possibly a suru-compound) back to
// the trie-backed dictionary lemma(s) it resolves to, plus the debug tooling that explains why.
// Split out of Segmenter.swift to keep that file under the line-count guardrail — buildLattice /
// Viterbi selection stay there since they're the lattice-construction half of the type; this file
// is the "given a surface, what does it mean" half. `isValidatedSuruNounPrefix` and
// `suruCompoundEdge` are internal (not private) because buildLattice calls them directly.
extension Segmenter {
    // Checks whether a surface string exists directly in the dictionary trie without deinflection.
    func containsSurface(_ surface: String) -> Bool {
        matchedTrieLemmas(for: surface).isEmpty == false
    }

    // Checks whether a surface resolves through the same trie plus deinflection path used by segmentation.
    func resolvesSurface(_ surface: String) -> Bool {
        resolvedTrieLemmas(for: surface).isEmpty == false
    }

    // Picks the highest-priority resolved lemma for a surface, preferring script-preserving kanji matches.
    func preferredLemma(for surface: String) -> String? {
        lemmaCandidates(for: surface).first
    }

    // Returns the trie-backed lemma candidates for `surface`, sorted
    // best-first by `preferredLemmaScore` with the same length / lexicographic
    // tiebreakers `preferredLemma` used to fold into a single answer. The
    // picker presents these to the user in this order, with the auto-picked
    // candidate appearing first.
    //
    // POS gating applies ONLY to `deinflected` candidates (see resolvedTrieLemmas) — surfaces the
    // deinflector reached via an actual conjugation-chain guess. Keep such a candidate only if it
    // EITHER has no known POS data at all (sparse dictionary data — an imperfect candidate is more
    // useful than none) OR has at least one entry whose POS confirms it actually conjugates
    // (verb/adjective). A candidate with KNOWN POS data that's confirmed non-conjugating (e.g.
    // noun-only) is excluded outright, even when it's the only trie hit reachable. This distinction
    // matters: an earlier version fell back to the FULL unfiltered set whenever nothing survived
    // the verb/adjective filter, which meant a coincidental deinflection chain landing on a real
    // but unrelated dictionary noun (どこかに →[に→ぬ]→ どこかぬ →[かぬ→く]→ どこく, JMdict's
    // archaic word for "Turkey") won by default — there was nothing else in the pool to prefer
    // it over. Distinguishing "no POS data" from "confirmed non-verb POS" (mirroring the same
    // distinction Lexicon.admittedLemmasAndPaths already makes for its own candidate gate) is
    // what lets this case return no candidate instead of a wrong one. When `surface == candidate`
    // the gate is skipped — the user typed the dictionary form directly, so all POS classes are
    // legitimate.
    //
    // `trusted` candidates (exact trie hits, iteration-mark expansions, kana-script normalization
    // like katakana スマイ → hiragana すまい) bypass the gate entirely: they're script/notation
    // equivalences, not conjugation guesses, so "does it conjugate" isn't a meaningful filter for
    // them — a common noun written in katakana must still resolve regardless of its POS.
    func lemmaCandidates(for surface: String) -> [String] {
        let (trusted, deinflected) = resolvedTrieLemmasBySource(for: surface)
        guard trusted.isEmpty == false || deinflected.isEmpty == false else { return [] }

        let gatedDeinflected = deinflected.filter { lemma in
            if lemma == surface { return true }
            guard let meta = trie.hitMeta(for: lemma), meta.entryIDs.isEmpty == false else { return true }
            let posBits = meta.entryIDs.map { partOfSpeechByEntryID[$0] ?? 0 }
            guard posBits.contains(where: { $0 != 0 }) else { return true }
            return posBits.contains { PartOfSpeech.isVerb($0) || PartOfSpeech.isAdjective($0) }
        }
        let pool = trusted.union(gatedDeinflected)

        return pool.sorted { lhs, rhs in
            let lhsScore = preferredLemmaScore(for: lhs, sourceSurface: surface)
            let rhsScore = preferredLemmaScore(for: rhs, sourceSurface: surface)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            let lhsFrequencyScore = preferredLemmaFrequencyScore(for: lhs)
            let rhsFrequencyScore = preferredLemmaFrequencyScore(for: rhs)
            if lhsFrequencyScore != rhsFrequencyScore {
                return lhsFrequencyScore > rhsFrequencyScore
            }
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs < rhs
        }
    }

    // Resolves all trie-backed lemmas reachable from a surface, including alternate candidates from the deinflector
    // and iteration mark expansion (々, ゝ, ヽ). Union of resolvedTrieLemmasBySource's two buckets, for callers
    // that only need "does anything resolve" / "list every reachable lemma" without the POS-gating distinction.
    // Internal (not private): buildLattice / debugPrintLattice, in Segmenter.swift, call this directly.
    func resolvedTrieLemmas(for surface: String) -> Set<String> {
        let (trusted, deinflected) = resolvedTrieLemmasBySource(for: surface)
        return trusted.union(deinflected)
    }

    // Same resolution as resolvedTrieLemmas, but split by source so lemmaCandidates can gate only
    // genuine deinflection guesses: `trusted` holds exact trie hits, iteration-mark expansions, and
    // kana-script normalization (katakana↔hiragana) — script/notation equivalences that hold
    // regardless of POS. `deinflected` holds candidates the deinflector reached via an actual
    // conjugation-chain guess, which POS gating uses to reject coincidental hits on a real but
    // unrelated non-conjugating word (see lemmaCandidates).
    private func resolvedTrieLemmasBySource(for surface: String) -> (trusted: Set<String>, deinflected: Set<String>) {
        var trusted = matchedTrieLemmas(for: surface)
        var deinflected = Set<String>()
        let hasExactSurfaceMatch = trie.contains(surface)

        // Expand iteration marks (e.g. 人々→人人) so reduplicated forms resolve through the trie.
        let expandedCandidates = ScriptClassifier.iterationExpandedCandidates(for: surface)
        for expanded in expandedCandidates where expanded != surface {
            trusted.formUnion(matchedTrieLemmas(for: expanded))
        }

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface)
            for candidate in candidates {
                let isKanaNormalized = deinflector.isNormalizedKanaCandidate(candidate, for: surface)
                if hasExactSurfaceMatch, candidate != surface, isKanaNormalized {
                    continue
                }
                if isKanaNormalized {
                    trusted.formUnion(matchedTrieLemmas(for: candidate))
                } else {
                    deinflected.formUnion(matchedTrieLemmas(for: candidate))
                }
            }

            // Second deinflection pass for derivational bases. A lexicalized れる/られる form
            // (生まれる, 流される) is a complete dictionary verb, so the first pass halts there and
            // never reaches its base (生む, 流す). But jpdb attaches frequency to the base, and the
            // base is a legitimate alternate lemma the user may want to see — so re-deinflect each
            // first-pass れる-form once more and add any trie-backed base as an ADDITIONAL candidate.
            // preferredLemmaScore still ranks the surface-closest lexicalized form first, so this
            // only widens the candidate set (feeding the frequency tiebreak + lemma picker); it does
            // not change the chosen primary lemma. Gated on the れる suffix to keep it cheap and
            // scoped to the passive/spontaneous/potential class where the base carries the frequency.
            let firstPassLemmas = trusted.union(deinflected)
            for lemma in firstPassLemmas where lemma != surface && lemma.hasSuffix("れる") {
                for base in deinflector.generateCandidates(for: lemma) where base != lemma {
                    deinflected.formUnion(matchedTrieLemmas(for: base))
                }
            }
        }

        return (trusted, deinflected)
    }

    // Builds a debug summary showing how the current resolver pipeline admits one emitted lemma for a surface.
    func debugResolutionSummary(for surface: String, lemma: String) -> String {
        let (exactLemmas, alternateResolutions) = debugResolutionSources(for: surface)
        let matchingAlternateCandidates = alternateResolutions
            .filter { resolution in
                resolution.lemmas.contains(lemma)
            }
            .map { resolution in
                resolution.candidate
            }
            .sorted()

        var parts = [
            "exact_hits: \(exactLemmas.count)",
            "alternate_hits: \(alternateResolutions.count)"
        ]

        if exactLemmas.contains(lemma) {
            parts.append("exact_match")
        }

        if matchingAlternateCandidates.isEmpty == false {
            parts.append("via: \(matchingAlternateCandidates.joined(separator: ", "))")
        }

        if let deinflector, lemma != surface {
            let transitions = deinflector.bestTransitions(for: surface, targetLemma: lemma) ?? []
            if transitions.isEmpty == false {
                let transStr = transitions.map { "\($0.kanaIn)→\($0.kanaOut)" }.joined(separator: ", ")
                parts.append("path: \(transStr)")
            }
        }

        return parts.joined(separator: "; ")
    }

    // Enumerates exact and alternate candidate resolutions using the same admission rules as lattice generation.
    private func debugResolutionSources(for surface: String) -> (exactLemmas: Set<String>, alternateResolutions: [(candidate: String, lemmas: Set<String>)]) {
        let exactLemmas = matchedTrieLemmas(for: surface)
        let hasExactSurfaceMatch = trie.contains(surface)
        var alternateResolutions: [(candidate: String, lemmas: Set<String>)] = []

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface).sorted()
            for candidate in candidates {
                if candidate == surface {
                    continue
                }

                if hasExactSurfaceMatch,
                   deinflector.isNormalizedKanaCandidate(candidate, for: surface) {
                    continue
                }

                let lemmas = matchedTrieLemmas(for: candidate)
                if lemmas.isEmpty == false {
                    alternateResolutions.append((candidate: candidate, lemmas: lemmas))
                }
            }
        }

        return (exactLemmas, alternateResolutions)
    }

    // Checks whether `prefix` alone (the leading katakana run, e.g. "キス") is an exact trie hit
    // tagged both noun AND verb — JMdict's collapsed "vs" signature (see PartOfSpeech.bits). This
    // is the half of the suru-compound shape that doesn't depend on how long the eventual する
    // conjugation suffix turns out to be, so buildLattice can gate scan-continuation on it alone.
    // Internal (not private): buildLattice, in Segmenter.swift, calls this directly.
    func isValidatedSuruNounPrefix(_ prefix: String) -> Bool {
        guard trie.contains(prefix) else { return false }
        let prefixPOS = trie.partOfSpeech(for: prefix)
        return PartOfSpeech.isNoun(prefixPOS) && PartOfSpeech.isVerb(prefixPOS)
    }

    // Validates the vs-noun+する compound-verb shape for `surface` (see buildLattice's mixed-script
    // guard) and returns the katakana noun prefix (e.g. "キス" for "キスして") when it holds, else nil.
    // Two conditions, both required: isValidatedSuruNounPrefix on the leading katakana run, and the
    // remainder independently deinflecting to bare する. Exposed (not private) so Lexicon can reuse
    // the same admission check for lookup/lemma display without duplicating it.
    func suruCompoundPrefix(for surface: String) -> String? {
        guard let prefix = ScriptClassifier.leadingKatakanaPrefix(of: surface), prefix.count < surface.count else {
            return nil
        }
        guard isValidatedSuruNounPrefix(prefix) else { return nil }

        let suffix = String(surface.dropFirst(prefix.count))
        guard suffix.isEmpty == false, trie.contains("する") else { return nil }
        guard let deinflector, deinflector.generateCandidates(for: suffix).contains("する") else { return nil }

        return prefix
    }

    // Builds a lattice edge for a validated suru-compound span, scored entirely from the noun
    // prefix's and する's own real trie data — never a synthetic "Xする" surface (JMdict deliberately
    // omits that headword; see the generate_db.py history for why literally synthesizing it doesn't
    // help segmentation and was reverted).
    // Internal (not private): buildLattice, in Segmenter.swift, calls this directly.
    func suruCompoundEdge(surface: String, range: Range<String.Index>) -> LatticeEdge? {
        guard let prefix = suruCompoundPrefix(for: surface) else { return nil }

        var edge = LatticeEdge(start: range.lowerBound, end: range.upperBound, surface: surface)
        edge.partOfSpeech = trie.partOfSpeech(for: prefix) | trie.partOfSpeech(for: "する")
        edge.isDictionaryMatch = true
        edge.frequencyScore = max(frequencyScoreBySurface[prefix] ?? 0, frequencyScoreBySurface["する"] ?? 0)
        if let ids = trie.ipadicContextIDs(for: "する") {
            edge.ipadicLeftID = ids.left
            edge.ipadicRightID = ids.right
        }
        return edge
    }

    // Resolves direct trie-backed membership lemmas for a surface without alternate-surface recovery.
    private func matchedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas: Set<String> = []

        if trie.contains(surface) {
            lemmas.insert(surface)
        }

        return lemmas
    }

    // Scores competing lemmas so furigana and segmentation can favor script-preserving dictionary forms.
    //
    // Frequency is deliberately excluded from this score. Callers compare it
    // separately only after the structural signals tie, so a common but weak
    // deinflection candidate cannot outrank a lemma that preserves more of the
    // source stem.
    // Internal (not private): compareEdgePriority, in Segmenter.swift, calls this directly.
    func preferredLemmaScore(for lemma: String, sourceSurface: String) -> Int {
        var score = 0

        if lemma == sourceSurface {
            score += LemmaScoring.surfaceEqualityBonus
        }

        if ScriptClassifier.containsKanji(sourceSurface) {
            if ScriptClassifier.containsKanji(lemma) {
                score += LemmaScoring.kanjiPreservedBonus
            } else if ScriptClassifier.isPureKana(lemma) {
                score += LemmaScoring.kanjiToKanaPenalty
            }
        }

        if ScriptClassifier.isPureKana(sourceSurface) && ScriptClassifier.isPureKana(lemma) {
            score += LemmaScoring.pureKanaBonus
        }

        // Prefer lemmas whose leading chars match the surface — the closer the
        // lemma's stem is to the surface, the more directly the deinflection
        // chain reached it. Disambiguates modern vs classical verbs that share
        // the same inflected form (e.g. 忘れる shares 「忘れ」 with 忘れない,
        // 忘る only 「忘」). 5 points per char yields ~10-point separation per
        // mora — enough to break ties without overpowering wordfreq or the
        // surface-equality bonus.
        let commonPrefixCount = lemma.commonPrefix(with: sourceSurface).count
        score += commonPrefixCount * LemmaScoring.prefixMatchPerChar

        return score
    }

    // Returns the corpus score used only to break structurally equal lemma candidates.
    // Internal (not private): compareEdgePriority, in Segmenter.swift, calls this directly.
    func preferredLemmaFrequencyScore(for lemma: String) -> Double {
        frequencyScoreBySurface[lemma] ?? 0
    }

    // Tunable structural weights for preferredLemmaScore. Grouped like SegmenterScoring's
    // transition costs so empirical calibration lives in one place instead of bare literals.
    private enum LemmaScoring {
        static let surfaceEqualityBonus = 100   // lemma identical to the surface form
        static let kanjiPreservedBonus = 40     // kanji surface → kanji lemma (script preserved)
        static let kanjiToKanaPenalty = -20     // kanji surface → kana-only lemma (script lost)
        static let pureKanaBonus = 10           // both surface and lemma are pure kana
        static let prefixMatchPerChar = 5       // per shared leading character
    }
}
