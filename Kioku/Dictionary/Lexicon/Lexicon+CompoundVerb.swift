import Foundation

// Compound-verb and phrasal-expression decomposition for Lexicon: detects te-form / i-stem
// auxiliary chains (消えてゆく, 買い始める) and splits case-particle phrases (夢を見る, 手が届く)
// into morpheme-level components.
extension Lexicon {
    // Detects compound verb components by examining deinflection transitions for auxiliary-stripping
    // steps. Returns the main lemma and each detected auxiliary as (lemma, first gloss) pairs, or nil
    // when the surface is not a compound verb.
    // For example, 消えてゆく → [(消える, "to disappear"), (行く, "to go")]
    // For phrasal surfaces containing case particles (夢を見てる, 手が届く), returns a morpheme-level
    // breakdown instead — the deinflection chain treating the trailing verb suffix as an auxiliary
    // would otherwise misreport the phrase as a verb compound (夢を見る + る "verb-forming suffix").
    public func compoundVerbComponents(surface: String) -> [(lemma: String, gloss: String?)]? {
        if let phrasal = phrasalComponentsForCaseParticleSurface(surface) {
            return phrasal
        }
        let (entries, pathsByLemma) = admittedLemmasAndPaths(for: surface)
        guard let best = entries.first else { return nil }
        guard let transitions = deinflector.bestTransitions(from: pathsByLemma, targetLemma: best.lemma),
              transitions.isEmpty == false else { return nil }

        // Walk transitions looking for auxiliary-stripping steps and recover the auxiliary
        // surface for each. Three patterns to handle:
        //
        //   1. te-form compounds (kanaIn=てゆく, kanaOut=て): kanaIn has kanaOut as a prefix,
        //      and the remainder is the auxiliary (ゆく).
        //   2. ichidan i-stem compounds (kanaIn=つづける, kanaOut=る): the entire kanaIn IS
        //      the auxiliary because v1 verbs have no stem change.
        //   3. godan i-stem compounds (kanaIn=しつづける, kanaOut=す): the FIRST char of
        //      kanaIn is the i-stem (し for す→し), the rest is the auxiliary (つづける).
        //
        // The previous implementation only handled case 1, so any compound built on a godan
        // verb's i-stem (買い始める, 飛び込む, さがしつづける, etc.) silently produced no
        // auxiliary chip in the lookup sheet. Try each strategy and take whichever resolves
        // to a real dictionary entry.
        var auxiliaries: [(lemma: String, gloss: String?)] = []
        for transition in transitions {
            guard transition.kanaIn.count > transition.kanaOut.count else { continue }
            // Candidate order matters: prefer the SHORTEST plausible auxiliary so that
            // surfaces like しつづける don't get reported as the full し続ける entry (which
            // also exists in JMdict) when the user actually wants just 続ける.
            // 1. strip-first-char — godan i-stem compounds (しつづける→つづける) AND te-form
            //    compounds (てゆく→ゆく), since the first char is the linker in both cases.
            // 2. strip-prefix — fallback for te-form compounds where kanaOut is multi-char.
            // 3. direct kanaIn — ichidan compounds (つづける with kanaOut=る) where there's
            //    no linker char to strip; the entire kanaIn IS the auxiliary.
            var candidates: [String] = []
            if transition.kanaIn.count > 1 {
                candidates.append(String(transition.kanaIn.dropFirst()))
            }
            if transition.kanaIn.hasPrefix(transition.kanaOut) {
                candidates.append(String(transition.kanaIn.dropFirst(transition.kanaOut.count)))
            }
            candidates.append(transition.kanaIn)
            var resolvedAux: DictionaryEntry?
            var resolvedSurface = ""
            for candidate in candidates where candidate.isEmpty == false {
                guard let entry = lookupEntries(for: candidate).first else { continue }
                guard entryHasVerbPOS(entry) else { continue }
                resolvedAux = entry
                resolvedSurface = candidate
                break
            }
            guard let auxEntry = resolvedAux else { continue }
            let gloss = auxEntry.senses.first?.glosses.joined(separator: "; ")
            let auxLemma = auxEntry.kanjiForms.first?.text ?? auxEntry.kanaForms.first?.text ?? resolvedSurface
            auxiliaries.append((lemma: auxLemma, gloss: gloss))
        }

        guard auxiliaries.isEmpty == false else { return nil }

        let mainGloss = lookupEntries(for: best.lemma).first?
            .senses.first?.glosses.joined(separator: "; ")
        var result: [(lemma: String, gloss: String?)] = [(lemma: best.lemma, gloss: mainGloss)]
        result.append(contentsOf: auxiliaries)
        return result
    }

    // JMdict POS codes for verbs start with `v` (v1, v5k, v5s, v5k-s, vi/vt, …); auxiliary-only
    // entries are tagged `aux`/`aux-v`/`aux-adj` and don't count. `vs*` codes mark suru-able nouns
    // rather than standalone verbs, so they're excluded too. Used to reject non-verb collisions
    // like past-tense た (aux-v), 区 (noun "ward"), って (particle "you said").
    private func entryHasVerbPOS(_ entry: DictionaryEntry) -> Bool {
        posCodes(for: entry).contains { code in
            code.hasPrefix("v") && code.hasPrefix("vs") == false
        }
    }

    // Idioms / phrasal verbs (夢を見る, 手が届く) carry `exp` alongside their verb class in JMdict,
    // marking them as multi-morpheme expressions rather than single-word verbs.
    private func entryIsPhrasalExpression(_ entry: DictionaryEntry) -> Bool {
        posCodes(for: entry).contains("exp")
    }

    // Returns lower-cased, comma-split, trimmed POS codes across every sense of the entry.
    private func posCodes(for entry: DictionaryEntry) -> [String] {
        entry.senses
            .compactMap { $0.pos?.lowercased() }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // True when the lemma resolves to a single-word verb entry (verb POS, not a phrasal `exp`).
    // Phrasal verb entries like 夢を見る are excluded so callers can still morpheme-split them.
    private func entryIsSingleWordVerb(lemma: String) -> Bool {
        lookupEntries(for: lemma).contains(where: { entry in
            entryHasVerbPOS(entry) && entryIsPhrasalExpression(entry) == false
        })
    }

    // Case particles を and が never appear inside a single-word verb conjugation; their presence
    // signals the surface is a phrase (noun + particle + verb) being looked up as one segment.
    // Splits the surface at these characters and returns morpheme-level components, deinflecting
    // the verbal portion to its dictionary form (見てる → 見る). Returns nil when the surface
    // contains no case particle so callers fall through to verb-compound detection.
    private func phrasalComponentsForCaseParticleSurface(_ surface: String) -> [(lemma: String, gloss: String?)]? {
        let caseParticles: Set<Character> = ["を", "が"]
        guard surface.contains(where: { caseParticles.contains($0) }) else { return nil }

        // The "を/が never appear inside a single-word verb" assumption breaks for native verbs
        // that literally contain these kana in their stem — 翻す (ひるがえす), 翻る (ひるがえる),
        // 流す (ながす), etc. If the surface deinflects to a single-word verb entry, treat it as
        // that verb rather than splitting it into morphemes around the embedded kana. Phrasal-verb
        // entries (夢を見る, tagged `exp,v1` in JMdict) deliberately fall through to morpheme split.
        let surfaceLemma = inflectionInfo(surface: surface)?.lemma ?? surface
        if entryIsSingleWordVerb(lemma: surfaceLemma) {
            return nil
        }

        var tokens: [String] = []
        var pendingToken = ""
        for character in surface {
            if caseParticles.contains(character) {
                if pendingToken.isEmpty == false {
                    tokens.append(pendingToken)
                    pendingToken = ""
                }
                tokens.append(String(character))
            } else {
                pendingToken.append(character)
            }
        }
        if pendingToken.isEmpty == false {
            tokens.append(pendingToken)
        }
        guard tokens.count > 1 else { return nil }

        let components: [(lemma: String, gloss: String?)] = tokens.map { token in
            let lemma = inflectionInfo(surface: token)?.lemma ?? token
            let gloss = lookupEntries(for: lemma).first?.senses.first?.glosses.first
            return (lemma: lemma, gloss: gloss)
        }
        return components
    }
}
