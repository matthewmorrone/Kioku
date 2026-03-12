import Foundation

// Generates deinflected dictionary candidate surfaces using rule-based state transitions.
final class Deinflector {

    private let rules: [DeinflectionRule]
    private let trie: DictionaryTrie
    private let maxDepth = 4
    private let grammaticalizedCompoundVerbSuffixes = [
        "つづける", "続ける",
        "はじめる", "始める",
        "おわる", "終わる",
        "だす", "出す",
        "すぎる", "過ぎる",
        "なおす", "直す",
        "きる", "切る",
        "かける", "掛ける",
    ]

    // Stores deinflection rules used by candidate generation.
    init(rules: [DeinflectionRule], trie: DictionaryTrie) {
        self.rules = rules.sorted { lhs, rhs in
            lhs.kanaIn.count > rhs.kanaIn.count
        }
        self.trie = trie
    }

    // Loads grouped rules from JSON data and flattens them into a linear rule list.
    static func loadRules(from data: Data) throws -> [DeinflectionRule] {
        let groupedRules = try JSONDecoder().decode([String: [DeinflectionRule]].self, from: data)
        return groupedRules.values.flatMap { groupRules in
            groupRules
        }
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

    // Builds a deinflector directly from a grouped-rule JSON file.
    convenience init(jsonFileURL: URL, trie: DictionaryTrie) throws {
        let rules = try Self.loadRules(from: jsonFileURL)
        self.init(rules: rules, trie: trie)
    }

    // Builds a deinflector from grouped-rule JSON in the app bundle.
    convenience init(
        trie: DictionaryTrie,
        bundle: Bundle = .main,
        resourceName: String = "deinflection",
        fileExtension: String = "json"
    ) throws {
        let rules = try Self.loadRules(bundle: bundle, resourceName: resourceName, fileExtension: fileExtension)
        self.init(rules: rules, trie: trie)
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
        candidates.formUnion(mixedScriptStemCandidates(for: surface))
        candidates.formUnion(grammaticalizedCompoundVerbCandidates(for: surface))
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

    // Resolves grammaticalized compound verbs like 追いつづける to first-verb lemma surfaces.
    private func grammaticalizedCompoundVerbCandidates(for surface: String) -> Set<String> {
        var candidates: Set<String> = []

        for suffix in grammaticalizedCompoundVerbSuffixes {
            guard surface.count > suffix.count, surface.hasSuffix(suffix) else {
                continue
            }

            let stemEndIndex = surface.index(surface.endIndex, offsetBy: -suffix.count)
            let headStem = String(surface[..<stemEndIndex])
            if headStem.isEmpty {
                continue
            }

            candidates.formUnion(verbStemCandidates(for: headStem))
        }

        return candidates
    }

    // Resolves continuative verb stems back to plausible dictionary-form candidate surfaces.
    private func verbStemCandidates(for surface: String) -> Set<String> {
        var candidates = mixedScriptStemCandidates(for: surface)

        if let trailingCharacter = surface.last,
           let dictionaryEnding = continuativeDictionaryEnding(for: trailingCharacter) {
            let dictionaryCandidate = String(surface.dropLast()) + String(dictionaryEnding)
            if trie.contains(dictionaryCandidate) {
                candidates.insert(dictionaryCandidate)
            }
        }

        if surface.isEmpty == false {
            let ichidanCandidate = surface + "る"
            if trie.contains(ichidanCandidate) {
                candidates.insert(ichidanCandidate)
            }
        }

        if surface == "し", trie.contains("する") {
            candidates.insert("する")
        }

        if surface == "き" || surface == "来" {
            if trie.contains("くる") {
                candidates.insert("くる")
            }
            if trie.contains("来る") {
                candidates.insert("来る")
            }
        }

        return candidates
    }

    // Resolves mixed-script continuative stems like 追い back to dictionary-form candidate surfaces.
    private func mixedScriptStemCandidates(for surface: String) -> Set<String> {
        guard ScriptClassifier.containsKanji(surface) else {
            return []
        }

        let characters = Array(surface)
        guard
            let trailingCharacter = characters.last,
            trailingCharacter.unicodeScalars.allSatisfy({ scalar in
                (0x3040...0x309F).contains(scalar.value)
            }),
            characters.dropLast().contains(where: { character in
                ScriptClassifier.containsKanji(String(character))
            })
        else {
            return []
        }

        guard let dictionaryEnding = continuativeDictionaryEnding(for: trailingCharacter) else {
            return []
        }

        let dictionaryCandidate = String(characters.dropLast()) + String(dictionaryEnding)
        guard trie.contains(dictionaryCandidate) else {
            return []
        }

        return [dictionaryCandidate]
    }

    // Maps continuative endings back to dictionary-form okurigana for verb recovery.
    private func continuativeDictionaryEnding(for character: Character) -> Character? {
        switch character {
        case "い":
            return "う"
        case "き":
            return "く"
        case "ぎ":
            return "ぐ"
        case "し":
            return "す"
        case "ち":
            return "つ"
        case "に":
            return "ぬ"
        case "び":
            return "ぶ"
        case "み":
            return "む"
        case "り":
            return "る"
        default:
            return nil
        }
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

    // Converts katakana scalars to hiragana for script-normalized lookup candidates.
    private func katakanaToHiragana(_ text: String) -> String {
        let convertedScalars = text.unicodeScalars.map { scalar -> UnicodeScalar in
            switch scalar.value {
            case 0x30A1...0x30F6, 0x30FD...0x30FE:
                return UnicodeScalar(scalar.value - 0x60) ?? scalar
            default:
                return scalar
            }
        }

        return String(String.UnicodeScalarView(convertedScalars))
    }
}
