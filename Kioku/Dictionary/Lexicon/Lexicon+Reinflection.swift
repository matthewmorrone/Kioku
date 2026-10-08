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

    // Up to `limit` other katakana する-nouns (JMdict `vs`) carrying the blank's own する ending, in
    // candidate order: キスした → ダンスした, テストした. Empty unless `surface` is a katakana noun+する
    // compound by the segmenter's own check (kanji ones segment as noun | する and need none of this).
    func suruCompoundsLike(
        surface: String,
        candidates: [(text: String, posTags: [String])],
        limit: Int
    ) -> [String] {
        guard limit > 0, let prefix = segmenter.suruCompoundPrefix(for: surface) else { return [] }
        let ending = String(surface.dropFirst(prefix.count))
        var results: [String] = []
        var seen: Set<String> = [surface]
        for candidate in candidates where candidate.text != prefix && ScriptClassifier.isPureKatakana(candidate.text) {
            guard candidate.posTags.contains("vs") else { continue }
            let compound = candidate.text + ending
            guard seen.insert(compound).inserted else { continue }
            results.append(compound)
            if results.count >= limit { break }
        }
        return results
    }

    // Up to `limit` other forms of `lemma`, one or two rule steps from it, in random order: した →
    // して, しない, する. For a blank whose conjugation class has no other dictionary words to inflect
    // alike (する, 来る, 行く, いい). A rule applies only when its output grammar is the lemma's (or the
    // previous step's) class, and of the rules in one form group that fit, only the one with the
    // longest ending: the rule data spells irregulars as stem-specific rules (行った → 行く beside
    // いた → く), so 行く yields 行った and never 行いた.
    func otherForms(of lemma: String, besides surface: String, limit: Int) -> [String] {
        let lemmaGrammars = ConjugationClass.grammars(forPOSStrings: posStrings(ofLemma: lemma))
        guard limit > 0, lemmaGrammars.isEmpty == false else { return [] }

        // Generating is string work; the deinflection check that confirms a form is the cost, so it
        // runs over a shuffled list only until `limit` forms pass.
        let rules = deinflector.labeledRulesForExpansion()
        var generated: [String] = []
        var seen: Set<String> = [lemma, surface]
        var frontier: [(surface: String, grammars: Set<String>)] = [(lemma, lemmaGrammars)]
        for _ in 0..<2 {
            var next: [(surface: String, grammars: Set<String>)] = []
            for state in frontier {
                for (form, grammars) in mostSpecificSteps(from: state.surface, grammars: state.grammars, rules: rules)
                where seen.contains(form) == false {
                    seen.insert(form)
                    next.append((form, grammars))
                    // A bare stem (食べ, し) shorter than the lemma isn't a word to offer.
                    if form.count >= lemma.count { generated.append(form) }
                }
            }
            frontier = next
        }

        var forms: [String] = []
        for form in generated.shuffled() where deinflector.deinflectionPaths(for: form)[lemma] != nil {
            forms.append(form)
            if forms.count >= limit { break }
        }
        return forms
    }

    // One inflection step from `surface`: per form group, the rules with the group's longest ending
    // among those whose output grammar is one of `grammars`, applied in reverse. Keyed by group alone
    // because a stem-specific rule doesn't share the generic one's input grammar (行った is `v5`, いた is
    // `ta`); ties are all kept, since one group holds many distinct forms (させる, しそう, しよう).
    private func mostSpecificSteps(
        from surface: String,
        grammars: Set<String>,
        rules: [(label: String, rule: DeinflectionRule)]
    ) -> [(form: String, grammars: Set<String>)] {
        var bestByGroup: [String: [DeinflectionRule]] = [:]
        for (label, rule) in rules
        where surface.hasSuffix(rule.kanaOut) && grammars.isDisjoint(with: rule.rulesOut) == false {
            let bestLength = bestByGroup[label]?.first?.kanaOut.count ?? -1
            if rule.kanaOut.count > bestLength {
                bestByGroup[label] = [rule]
            } else if rule.kanaOut.count == bestLength {
                bestByGroup[label, default: []].append(rule)
            }
        }
        return bestByGroup.keys.sorted().flatMap { key in
            (bestByGroup[key] ?? []).map { rule in
                (String(surface.dropLast(rule.kanaOut.count)) + rule.kanaIn, Set(rule.rulesIn))
            }
        }
    }

    // The exact conjugating JMdict tags of the entries that spell `lemma` verbatim.
    private func conjugationTags(ofLemma lemma: String) -> Set<String> {
        ConjugationClass.conjugatingTags(in: posStrings(ofLemma: lemma).flatMap { $0.components(separatedBy: ",") })
    }

    // The comma-joined POS strings of every sense of the entries that spell `lemma` verbatim.
    private func posStrings(ofLemma lemma: String) -> [String] {
        lookupEntries(for: lemma)
            .filter { entry in
                entry.kanjiForms.contains { $0.text == lemma } || entry.kanaForms.contains { $0.text == lemma }
            }
            .flatMap { $0.senses.compactMap(\.pos) }
    }
}
