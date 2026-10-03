import Foundation

// Shared type for pre-computed deinflection path results, passed between Deinflector and Lexicon to avoid re-traversal.
typealias DeinflectionPathMap = [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]]

// Generates deinflected dictionary candidate surfaces using rule-based state transitions.
nonisolated final class Deinflector {

    private let rules: [DeinflectionRule]
    private let labeledRules: [(label: String, rule: DeinflectionRule)]
    private let trie: DictionaryTrie

    // Godan verbs that end in -iru/-eru and are commonly mistaken for ichidan (the textbook
    // "exception" list: their て-form takes the small-っ godan pattern — 知って, not 知て —
    // so they never legitimately match a rule whose rulesOut claims ["v1"]). Consulted by
    // deinflectionPaths to reject false-ichidan candidates a generic v1 rule would otherwise
    // admit. Sourced from the dictionary's deinflection_lists (nonIchidanRuVerbs)
    // rather than hard-coded here, per the Deinflection Contract — Deinflector may only load
    // rules, traverse the rule graph, and admit candidates, not embed word-specific exceptions.
    //
    // Deliberately excludes exception-class readings that ALSO have a real ichidan homophone
    // (verified against dictionary.sqlite, not assumed) — denylisting those would break the
    // legitimate ichidan verb instead of just rejecting the godan false-positive:
    //   いる (要る godan vs 居る/射る ichidan), かえる (帰る godan vs 変える ichidan),
    //   きる (切る godan vs 着る ichidan), へる (減る godan vs 経る ichidan).
    private let knownNonIchidanRuVerbs: Set<String>

    // Grammar states that are a step inside a chain, not a dictionary form: a rule whose rulesOut
    // names one (てく → て, rulesOut ["te"]) says "this is a て-form", so the surface it leaves is
    // traversed further but is never a lemma candidate — otherwise についてく → について would admit
    // the expression について as the word. Sourced from the dictionary's deinflection_lists (intermediateForms).
    private let intermediateForms: Set<String>

    // The helper word (DeinflectionRule.helper) of each rule that has one, keyed by helperKey.
    let helperByTransition: [String: String]

    // Each rule's rulesOut, keyed by helperKey — what grammar a chain ending on that rule claims.
    let rulesOutByTransition: [String: Set<String>]

    // Stores deinflection rules used by candidate generation.
    init(rules: [DeinflectionRule], trie: DictionaryTrie, nonIchidanRuVerbs: Set<String> = [], intermediateForms: Set<String> = []) {
        self.rules = rules.sorted { lhs, rhs in
            lhs.kanaIn.count > rhs.kanaIn.count
        }
        self.labeledRules = self.rules.map { rule in
            (label: "rule", rule: rule)
        }
        self.trie = trie
        self.knownNonIchidanRuVerbs = nonIchidanRuVerbs
        self.intermediateForms = intermediateForms
        self.helperByTransition = Self.helperIndex(self.labeledRules, normalizingLabel: Self.normalizedRuleLabel)
        self.rulesOutByTransition = Self.rulesOutIndex(self.labeledRules, normalizingLabel: Self.normalizedRuleLabel)
    }

    // Stores grouped deinflection rules while preserving group labels used for chain reporting.
    init(groupedRules: [String: [DeinflectionRule]], trie: DictionaryTrie, nonIchidanRuVerbs: Set<String> = [], intermediateForms: Set<String> = []) {
        let expandedLabeledRules = groupedRules
            .flatMap { label, grouped in
                grouped.map { rule in
                    (label: label, rule: rule)
                }
            }
            .sorted { lhs, rhs in
                lhs.rule.kanaIn.count > rhs.rule.kanaIn.count
            }

        self.labeledRules = expandedLabeledRules
        self.rules = expandedLabeledRules.map { labeledRule in
            labeledRule.rule
        }
        self.trie = trie
        self.knownNonIchidanRuVerbs = nonIchidanRuVerbs
        self.intermediateForms = intermediateForms
        self.helperByTransition = Self.helperIndex(expandedLabeledRules, normalizingLabel: Self.normalizedRuleLabel)
        self.rulesOutByTransition = Self.rulesOutIndex(expandedLabeledRules, normalizingLabel: Self.normalizedRuleLabel)
    }

    // Builds a deinflector from the rules the dictionary carries (DictionaryStore.fetchDeinflectionRuleSet).
    convenience init(ruleSet: DeinflectionRuleSet, trie: DictionaryTrie) {
        self.init(
            groupedRules: ruleSet.groupedRules,
            trie: trie,
            nonIchidanRuVerbs: ruleSet.nonIchidanRuVerbs,
            intermediateForms: ruleSet.intermediateForms
        )
    }

    // Returns ordered labeled rules so callers can perform inflection inversion without reloading rule resources.
    func labeledRulesForExpansion() -> [(label: String, rule: DeinflectionRule)] {
        labeledRules
    }

    // Builds all reachable deinflection traces so callers can derive both lemma candidates and grouped-rule chains.
    // Termination is guaranteed by the visited set: once a (surface, grammar) pair is processed,
    // it is never re-enqueued regardless of path length, so the BFS exhausts a finite state space.
    func deinflectionPaths(
        for surface: String
    ) -> [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]] {
        var pathsBySurface: [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]] = [:]
        var visited = Set<DeinflectionState>()
        var queue: [(
            surface: String,
            grammar: String?,
            chain: [String],
            transitions: [(label: String, kanaIn: String, kanaOut: String)]
        )] = [
            (surface: surface, grammar: nil, chain: [], transitions: [])
        ]
        // Rules match hiragana endings, so a verb written in katakana for effect (ナカナイ) is also
        // traversed in its hiragana form (なかない → なく). A katakana surface the dictionary already
        // knows as a word (ゼッタイ), or whose hiragana form is a word (スマイ → すまい, not すまう),
        // is not re-read as an inflection.
        if trie.contains(surface) == false {
            for normalized in normalizedKanaCandidates(for: surface).sorted() where trie.contains(normalized) == false {
                queue.append((surface: normalized, grammar: nil, chain: [], transitions: []))
            }
        }

        var cursor = 0
        while cursor < queue.count {
            let item = queue[cursor]
            cursor += 1

            let state = DeinflectionState(surface: item.surface, grammar: item.grammar)
            if visited.contains(state) {
                continue
            }

            visited.insert(state)
            if item.grammar.map({ intermediateForms.contains($0) }) != true {
                pathsBySurface[item.surface, default: []].append((chain: item.chain, transitions: item.transitions))
            }

            for labeledRule in labeledRules {
                let rule = labeledRule.rule
                if item.surface.hasSuffix(rule.kanaIn) == false {
                    continue
                }

                if let currentGrammar = item.grammar,
                   rule.rulesIn.contains(currentGrammar) == false {
                    continue
                }

                let stem = item.surface.dropLast(rule.kanaIn.count)
                let candidateSurface = String(stem) + rule.kanaOut
                // An empty stem means the whole surface matched the rule's input.
                // For a generic suffix (た, て, ない) that's just a bare ending
                // and can't form a word — reject it. But the irregular する/くる
                // verbs conjugate as whole words (した⇒する, きた⇒くる, して⇒する),
                // so kanaIn IS the entire conjugated form and kanaOut is itself a
                // real verb. Admit those when the trie confirms the result is a
                // word; the kanaIn ≥ 2 check excludes single-kana stem-recovery
                // rules (し⇒する, き⇒くる) that genuinely need a preceding stem.
                if stem.isEmpty {
                    guard rule.kanaIn.count >= 2, trie.contains(candidateSurface) else { continue }
                }
                // A rule claiming rulesOut ["v1"] doesn't verify the candidate is actually
                // ichidan — PartOfSpeech only tracks a coarse "verb" bit (v1/v5/vs/vk all
                // collapse to the same flag), so there's no cheap way to check this generally.
                // But a small, well-known class of godan verbs LOOK ichidan (end in -iru/-eru)
                // and collide with genuine ichidan contraction rules: 知る's real contraction
                // is 知っちゃう/しっちゃう (small っ, godan て-form), never しちゃう — yet the
                // generic v1 "ちゃう→る" rule strips just "ちゃう" and produces "しる" as a
                // false ichidan candidate, which then out-competes the correct "する" candidate
                // (from an explicit irregular rule) in lemma ranking. Denylist known offenders
                // rather than let this rule admit them under a grammar class they don't have.
                if rule.rulesOut.contains("v1"), knownNonIchidanRuVerbs.contains(candidateSurface) {
                    continue
                }
                let chainItem = Self.normalizedRuleLabel(labeledRule.label)

                for nextGrammar in rule.rulesOut {
                    let nextChain = item.chain + [chainItem]
                    let nextTransitions = item.transitions + [
                        (label: chainItem, kanaIn: rule.kanaIn, kanaOut: rule.kanaOut)
                    ]

                    queue.append(
                        (
                            surface: candidateSurface,
                            grammar: nextGrammar,
                            chain: nextChain,
                            transitions: nextTransitions
                        )
                    )
                }
            }
        }

        return pathsBySurface
    }

    // Picks transitions for one surface-to-lemma path so reading projection can preserve inflection morphology.
    func bestTransitions(
        for surface: String,
        targetLemma: String
    ) -> [(label: String, kanaIn: String, kanaOut: String)]? {
        bestTransitions(from: deinflectionPaths(for: surface), targetLemma: targetLemma)
    }

    // Picks transitions from pre-computed paths, avoiding a redundant deinflection traversal.
    func bestTransitions(
        from pathsByLemma: DeinflectionPathMap,
        targetLemma: String
    ) -> [(label: String, kanaIn: String, kanaOut: String)]? {
        let paths = pathsByLemma[targetLemma] ?? []
        guard paths.isEmpty == false else {
            return nil
        }

        let bestPath = paths.min { lhs, rhs in
            if lhs.chain.count != rhs.chain.count {
                return lhs.chain.count < rhs.chain.count
            }

            return lhs.chain.joined(separator: ",") < rhs.chain.joined(separator: ",")
        }

        return bestPath?.transitions
    }

    // Picks grouped-rule labels for one surface-to-lemma path using shortest-path tie breaking.
    func inflectionChain(for surface: String, targetLemma: String) -> [String] {
        inflectionChain(from: deinflectionPaths(for: surface), targetLemma: targetLemma)
    }

    // Picks chain labels from pre-computed paths, avoiding a redundant deinflection traversal.
    func inflectionChain(from pathsByLemma: DeinflectionPathMap, targetLemma: String) -> [String] {
        let paths = pathsByLemma[targetLemma] ?? []
        guard paths.isEmpty == false else {
            return []
        }

        let bestPath = paths.min { lhs, rhs in
            if lhs.chain.count != rhs.chain.count {
                return lhs.chain.count < rhs.chain.count
            }

            return lhs.chain.joined(separator: ",") < rhs.chain.joined(separator: ",")
        }

        return bestPath?.chain ?? []
    }

    // Produces candidate dictionary surfaces by delegating to deinflectionPaths and adding alternate surface forms.
    // deinflectionPaths is the canonical traversal; this adds kana normalization and iteration-mark expansions on top.
    func generateCandidates(for surface: String) -> Set<String> {
        generateCandidates(from: deinflectionPaths(for: surface))
    }

    // Same candidate set, from an already-computed traversal — lets a caller that also needs the
    // chain lengths (the segmenter's inflection-step cost) pay for deinflectionPaths only once.
    func generateCandidates(from paths: DeinflectionPathMap) -> Set<String> {
        var results = Set(paths.keys)
        for candidate in paths.keys {
            results.formUnion(alternateSurfaceCandidates(for: candidate))
        }
        return results
    }

    // Provides a concise deinflection API used by segmentation pipeline integration.
    func deinflect(_ surface: String) -> Set<String> {
        generateCandidates(for: surface)
    }

    // Detects whether a candidate came from kana normalization of the original surface.
    func isNormalizedKanaCandidate(_ candidate: String, for surface: String) -> Bool {
        normalizedKanaCandidates(for: surface).contains(candidate)
    }

    // Collects all alternate surfaces owned by the normalization and recovery layer.
    private func alternateSurfaceCandidates(for surface: String) -> Set<String> {
        var candidates = normalizedKanaCandidates(for: surface)
        candidates.formUnion(ScriptClassifier.iterationExpandedCandidates(for: surface))
        return candidates
    }

    // Produces kana-normalized candidates while rejecting arbitrary mixed-script noise.
    private func normalizedKanaCandidates(for surface: String) -> Set<String> {
        var candidates: Set<String> = []

        if ScriptClassifier.isPureKatakana(surface) {
            let hiraganaSurface = katakanaToHiraganaExpandingLongVowels(surface)
            if hiraganaSurface != surface {
                candidates.insert(hiraganaSurface)
            }
            return candidates
        }

        guard let katakanaPrefixLength = katakanaLeadingPrefixLength(in: surface) else {
            return candidates
        }

        let prefixEndIndex = surface.index(surface.startIndex, offsetBy: katakanaPrefixLength)
        let katakanaPrefix = String(surface[..<prefixEndIndex])
        let hiraganaSuffix = String(surface[prefixEndIndex...])
        guard ScriptClassifier.isPureHiragana(hiraganaSuffix) else {
            return candidates
        }

        let normalizedPrefix = katakanaToHiraganaExpandingLongVowels(katakanaPrefix)
        let normalizedSurface = normalizedPrefix + hiraganaSuffix
        if normalizedSurface != surface {
            candidates.insert(normalizedSurface)
        }

        return candidates
    }

    // Returns the length of a katakana-only leading prefix when the surface starts with katakana.
    private func katakanaLeadingPrefixLength(in surface: String) -> Int? {
        guard surface.isEmpty == false else {
            return nil
        }

        var prefixLength = 0
        for character in surface {
            let scalarValues = character.unicodeScalars.map(\.value)
            let isKatakanaCharacter = scalarValues.allSatisfy { value in
                (0x30A0...0x30FF).contains(value) || value == 0x30FC
            }

            if isKatakanaCharacter {
                prefixLength += 1
                continue
            }

            break
        }

        return prefixLength > 0 ? prefixLength : nil
    }

    // Converts katakana scalars to hiragana, expanding the prolonged sound mark ー to the appropriate
    // vowel based on the preceding mora. This is required so that ショーブ resolves to しょうぶ rather
    // than しょーぶ, which is the form stored in JMdict.
    private func katakanaToHiraganaExpandingLongVowels(_ text: String) -> String {
        var result: [UnicodeScalar] = []
        // Tracks the most recently emitted hiragana scalar so ー can expand relative to it.
        var previousHiragana: UnicodeScalar? = nil

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x30A1...0x30F6, 0x30FD...0x30FE:
                // Standard katakana → hiragana offset conversion.
                let hiragana = UnicodeScalar(scalar.value - 0x60) ?? scalar
                result.append(hiragana)
                previousHiragana = hiragana
            case 0x30FC:
                // ー: expand to the vowel that lengthens the preceding mora.
                if let prev = previousHiragana {
                    let expanded = longVowelExpansion(for: prev)
                    result.append(expanded)
                    previousHiragana = expanded
                } else {
                    result.append(scalar)
                }
            default:
                result.append(scalar)
                previousHiragana = nil
            }
        }

        return String(String.UnicodeScalarView(result))
    }

    // Maps a hiragana character to the hiragana vowel that follows a prolonged sound mark (ー) in its mora row.
    // お段 maps to う rather than お because standard Japanese orthography writes long /o/ as おう.
    // え段 maps to い for the same reason (standard spelling of long /e/ as えい).
    private func longVowelExpansion(for hiragana: UnicodeScalar) -> UnicodeScalar {
        switch hiragana.value {
        // あ段
        case 0x3041, 0x3042,                         // ぁあ
             0x304B, 0x304C,                         // かが
             0x3055, 0x3056,                         // さざ
             0x305F, 0x3060,                         // ただ
             0x306A,                                 // な
             0x306F, 0x3070, 0x3071,                 // はばぱ
             0x307E,                                 // ま
             0x3083, 0x3084,                         // ゃや
             0x3089,                                 // ら
             0x308E, 0x308F:                         // ゎわ
            return UnicodeScalar(0x3042)!            // → あ
        // い段
        case 0x3043, 0x3044,                         // ぃい
             0x304D, 0x304E,                         // きぎ
             0x3057, 0x3058,                         // しじ
             0x3061, 0x3062,                         // ちぢ
             0x306B,                                 // に
             0x3072, 0x3073, 0x3074,                 // ひびぴ
             0x307F,                                 // み
             0x308A,                                 // り
             0x3090:                                 // ゐ
            return UnicodeScalar(0x3044)!            // → い
        // う段
        case 0x3045, 0x3046,                         // ぅう
             0x304F, 0x3050,                         // くぐ
             0x3059, 0x305A,                         // すず
             0x3063, 0x3064, 0x3065,                 // っつづ
             0x306C,                                 // ぬ
             0x3075, 0x3076, 0x3077,                 // ふぶぷ
             0x3080,                                 // む
             0x3085, 0x3086,                         // ゅゆ
             0x308B,                                 // る
             0x3094:                                 // ゔ
            return UnicodeScalar(0x3046)!            // → う
        // え段 → い (standard long-e spelling)
        case 0x3047, 0x3048,                         // ぇえ
             0x3051, 0x3052,                         // けげ
             0x305B, 0x305C,                         // せぜ
             0x3066, 0x3067,                         // てで
             0x306D,                                 // ね
             0x3078, 0x3079, 0x307A,                 // へべぺ
             0x3081,                                 // め
             0x308C,                                 // れ
             0x3091:                                 // ゑ
            return UnicodeScalar(0x3044)!            // → い
        // お段 → う (standard long-o spelling)
        case 0x3049, 0x304A,                         // ぉお
             0x3053, 0x3054,                         // こご
             0x305D, 0x305E,                         // そぞ
             0x3068, 0x3069,                         // とど
             0x306E,                                 // の
             0x307B, 0x307C, 0x307D,                 // ほぼぽ
             0x3082,                                 // も
             0x3087, 0x3088,                         // ょよ
             0x308D,                                 // ろ
             0x3092:                                 // を
            return UnicodeScalar(0x3046)!            // → う
        default:
            // No expansion rule (e.g. ん); keep the prolonged sound mark as-is.
            return UnicodeScalar(0x30FC)!
        }
    }

    // Normalizes one grouped-rule label from JSON key format to displayable inflection term.
    static func normalizedRuleLabel(_ label: String) -> String {
        if label.hasSuffix("Forms") {
            return splitCamelCase(String(label.dropLast(5))).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return splitCamelCase(label).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Splits camel-cased tokens into lowercase space-delimited words for human-readable chain labels.
    private static func splitCamelCase(_ text: String) -> String {
        guard text.isEmpty == false else {
            return text
        }

        var output = ""
        for character in text {
            if character.isUppercase {
                output.append(" ")
                output.append(character.lowercased())
            } else {
                output.append(character)
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
