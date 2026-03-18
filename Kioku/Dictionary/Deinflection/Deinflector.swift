import Foundation

// Shared type for pre-computed deinflection path results, passed between Deinflector and Lexicon to avoid re-traversal.
typealias DeinflectionPathMap = [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]]

// Generates deinflected dictionary candidate surfaces using rule-based state transitions.
final class Deinflector {

    private let rules: [DeinflectionRule]
    private let labeledRules: [(label: String, rule: DeinflectionRule)]
    private let trie: DictionaryTrie
    private let maxDepth = 4

    // Stores deinflection rules used by candidate generation.
    init(rules: [DeinflectionRule], trie: DictionaryTrie) {
        self.rules = rules.sorted { lhs, rhs in
            lhs.kanaIn.count > rhs.kanaIn.count
        }
        self.labeledRules = self.rules.map { rule in
            (label: "rule", rule: rule)
        }
        self.trie = trie
    }

    // Stores grouped deinflection rules while preserving group labels used for chain reporting.
    init(groupedRules: [String: [DeinflectionRule]], trie: DictionaryTrie) {
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
    }

    // Loads grouped rules from JSON data while preserving rule-group labels.
    static func loadGroupedRules(from data: Data) throws -> [String: [DeinflectionRule]] {
        try JSONDecoder().decode([String: [DeinflectionRule]].self, from: data)
    }

    // Loads grouped rules from JSON data and flattens them into a linear rule list.
    static func loadRules(from data: Data) throws -> [DeinflectionRule] {
        let groupedRules = try loadGroupedRules(from: data)
        return groupedRules.values.flatMap { groupRules in
            groupRules
        }
    }

    // Loads grouped rules from a JSON file URL while preserving group labels.
    static func loadGroupedRules(from fileURL: URL) throws -> [String: [DeinflectionRule]] {
        let data = try Data(contentsOf: fileURL)
        return try loadGroupedRules(from: data)
    }

    // Loads grouped rules from a JSON file URL and flattens them into a linear rule list.
    static func loadRules(from fileURL: URL) throws -> [DeinflectionRule] {
        let data = try Data(contentsOf: fileURL)
        return try loadRules(from: data)
    }

    // Loads grouped rules from a JSON file in the provided app bundle.
    static func loadRules(
        bundle: Bundle = .main,
        resourceName: String = "deinflection",
        fileExtension: String = "json"
    ) throws -> [DeinflectionRule] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            throw NSError(
                domain: "Deinflector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing deinflection rules file: \(resourceName).\(fileExtension)"]
            )
        }

        return try loadRules(from: fileURL)
    }

    // Loads grouped rules from a JSON file in the provided app bundle while preserving labels.
    static func loadGroupedRules(
        bundle: Bundle = .main,
        resourceName: String = "deinflection",
        fileExtension: String = "json"
    ) throws -> [String: [DeinflectionRule]] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            throw NSError(
                domain: "Deinflector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing deinflection rules file: \(resourceName).\(fileExtension)"]
            )
        }

        return try loadGroupedRules(from: fileURL)
    }

    // Builds a deinflector directly from a grouped-rule JSON file.
    convenience init(jsonFileURL: URL, trie: DictionaryTrie) throws {
        let groupedRules = try Self.loadGroupedRules(from: jsonFileURL)
        self.init(groupedRules: groupedRules, trie: trie)
    }

    // Builds a deinflector from grouped-rule JSON in the app bundle.
    convenience init(
        trie: DictionaryTrie,
        bundle: Bundle = .main,
        resourceName: String = "deinflection",
        fileExtension: String = "json"
    ) throws {
        let groupedRules = try Self.loadGroupedRules(bundle: bundle, resourceName: resourceName, fileExtension: fileExtension)
        self.init(groupedRules: groupedRules, trie: trie)
    }

    // Returns ordered labeled rules so callers can perform inflection inversion without reloading rule resources.
    func labeledRulesForExpansion() -> [(label: String, rule: DeinflectionRule)] {
        labeledRules
    }

    // Builds all reachable deinflection traces so callers can derive both lemma candidates and grouped-rule chains.
    func deinflectionPaths(
        for surface: String
    ) -> [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]] {
        var pathsBySurface: [String: [(chain: [String], transitions: [(label: String, kanaIn: String, kanaOut: String)])]] = [:]
        var visited = Set<DeinflectionState>()
        var queue: [(
            surface: String,
            grammar: String?,
            depth: Int,
            chain: [String],
            transitions: [(label: String, kanaIn: String, kanaOut: String)]
        )] = [
            (surface: surface, grammar: nil, depth: 0, chain: [], transitions: [])
        ]

        var cursor = 0
        while cursor < queue.count {
            let item = queue[cursor]
            cursor += 1

            let state = DeinflectionState(surface: item.surface, grammar: item.grammar, depth: item.depth)
            if visited.contains(state) {
                continue
            }

            visited.insert(state)
            pathsBySurface[item.surface, default: []].append((chain: item.chain, transitions: item.transitions))

            if item.depth >= maxDepth {
                continue
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
                let chainItem = normalizedRuleLabel(labeledRule.label)

                for nextGrammar in rule.rulesOut {
                    let nextChain = item.chain + [chainItem]
                    let nextTransitions = item.transitions + [
                        (label: chainItem, kanaIn: rule.kanaIn, kanaOut: rule.kanaOut)
                    ]

                    queue.append(
                        (
                            surface: candidateSurface,
                            grammar: nextGrammar,
                            depth: item.depth + 1,
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

    // Performs BFS over deinflection states to produce candidate dictionary surfaces.
    func generateCandidates(for surface: String) -> Set<String> {

        var results: Set<String> = [surface]
        results.formUnion(alternateSurfaceCandidates(for: surface))
        var visited: Set<DeinflectionState> = []
        var queue: [DeinflectionState] = [DeinflectionState(surface: surface, grammar: nil, depth: 0)]

        while !queue.isEmpty {

            let state = queue.removeFirst()

            if visited.contains(state) { continue }
            visited.insert(state)

            if state.depth >= maxDepth {
                continue
            }

            for rule in rules {

                if !state.surface.hasSuffix(rule.kanaIn) { continue }

                if let grammar = state.grammar,
                   !rule.rulesIn.contains(grammar) {
                    continue
                }

                let stem = state.surface.dropLast(rule.kanaIn.count)
                let candidate = String(stem) + rule.kanaOut

                for nextGrammar in rule.rulesOut {

                    let newState = DeinflectionState(surface: candidate, grammar: nextGrammar, depth: state.depth + 1)

                    if !visited.contains(newState) {
                        queue.append(newState)
                        results.insert(candidate)
                        results.formUnion(alternateSurfaceCandidates(for: candidate))
                    }
                }
            }
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
            let hiraganaSurface = katakanaToHiragana(surface)
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

        let normalizedPrefix = katakanaToHiragana(katakanaPrefix)
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
    private func katakanaToHiragana(_ text: String) -> String {
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
             0x306A,                                  // な
             0x306F, 0x3070, 0x3071,                 // はばぱ
             0x307E,                                  // ま
             0x3083, 0x3084,                         // ゃや
             0x3089,                                  // ら
             0x308E, 0x308F:                         // ゎわ
            return UnicodeScalar(0x3042)!            // → あ
        // い段
        case 0x3043, 0x3044,                         // ぃい
             0x304D, 0x304E,                         // きぎ
             0x3057, 0x3058,                         // しじ
             0x3061, 0x3062,                         // ちぢ
             0x306B,                                  // に
             0x3072, 0x3073, 0x3074,                 // ひびぴ
             0x307F,                                  // み
             0x308A,                                  // り
             0x3090:                                  // ゐ
            return UnicodeScalar(0x3044)!            // → い
        // う段
        case 0x3045, 0x3046,                         // ぅう
             0x304F, 0x3050,                         // くぐ
             0x3059, 0x305A,                         // すず
             0x3063, 0x3064, 0x3065,                 // っつづ
             0x306C,                                  // ぬ
             0x3075, 0x3076, 0x3077,                 // ふぶぷ
             0x3080,                                  // む
             0x3085, 0x3086,                         // ゅゆ
             0x308B,                                  // る
             0x3094:                                  // ゔ
            return UnicodeScalar(0x3046)!            // → う
        // え段 → い (standard long-e spelling)
        case 0x3047, 0x3048,                         // ぇえ
             0x3051, 0x3052,                         // けげ
             0x305B, 0x305C,                         // せぜ
             0x3066, 0x3067,                         // てで
             0x306D,                                  // ね
             0x3078, 0x3079, 0x307A,                 // へべぺ
             0x3081,                                  // め
             0x308C,                                  // れ
             0x3091:                                  // ゑ
            return UnicodeScalar(0x3044)!            // → い
        // お段 → う (standard long-o spelling)
        case 0x3049, 0x304A,                         // ぉお
             0x3053, 0x3054,                         // こご
             0x305D, 0x305E,                         // そぞ
             0x3068, 0x3069,                         // とど
             0x306E,                                  // の
             0x307B, 0x307C, 0x307D,                 // ほぼぽ
             0x3082,                                  // も
             0x3087, 0x3088,                         // ょよ
             0x308D,                                  // ろ
             0x3092:                                  // を
            return UnicodeScalar(0x3046)!            // → う
        default:
            // No expansion rule (e.g. ん); keep the prolonged sound mark as-is.
            return UnicodeScalar(0x30FC)!
        }
    }

    // Normalizes one grouped-rule label from JSON key format to displayable inflection term.
    private func normalizedRuleLabel(_ label: String) -> String {
        if label.hasSuffix("Forms") {
            return splitCamelCase(String(label.dropLast(5))).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return splitCamelCase(label).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Splits camel-cased tokens into lowercase space-delimited words for human-readable chain labels.
    private func splitCamelCase(_ text: String) -> String {
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
