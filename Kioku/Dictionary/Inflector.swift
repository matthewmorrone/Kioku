import Foundation

// Generates inflected surface candidates from a lemma using rule-based state transitions.
final class Inflector {

    private let rules: [InflectionRule]
    private let maxDepth = 4

    // Stores inflection rules used by form generation.
    init(rules: [InflectionRule]) {
        self.rules = rules.sorted { lhs, rhs in
            lhs.kanaIn.count > rhs.kanaIn.count
        }
    }

    // Loads grouped rules from JSON data and flattens them into a linear rule list.
    static func loadRules(from data: Data) throws -> [InflectionRule] {
        let groupedRules = try JSONDecoder().decode([String: [InflectionRule]].self, from: data)
        return groupedRules.values.flatMap { $0 }
    }

    // Loads grouped rules from a JSON file URL and flattens them into a linear rule list.
    static func loadRules(from fileURL: URL) throws -> [InflectionRule] {
        let data = try Data(contentsOf: fileURL)
        return try loadRules(from: data)
    }

    // Loads grouped rules from a JSON file in the provided app bundle.
    static func loadRules(
        bundle: Bundle = .main,
        resourceName: String = "inflection",
        fileExtension: String = "json"
    ) throws -> [InflectionRule] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            throw NSError(
                domain: "Inflector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing inflection rules file: \(resourceName).\(fileExtension)"]
            )
        }

        return try loadRules(from: fileURL)
    }

    // Builds an inflector from a JSON file URL.
    convenience init(jsonFileURL: URL) throws {
        let rules = try Self.loadRules(from: jsonFileURL)
        self.init(rules: rules)
    }

    // Builds an inflector from a JSON file in the app bundle.
    convenience init(
        bundle: Bundle = .main,
        resourceName: String = "inflection",
        fileExtension: String = "json"
    ) throws {
        let rules = try Self.loadRules(bundle: bundle, resourceName: resourceName, fileExtension: fileExtension)
        self.init(rules: rules)
    }

    // Performs BFS over inflection states to produce candidate inflected surfaces from a lemma.
    func generateForms(for lemma: String) -> Set<String> {
        var results: Set<String> = [lemma]
        var visited: Set<InflectionState> = []
        var queue: [InflectionState] = [InflectionState(surface: lemma, grammar: nil, depth: 0)]

        while queue.isEmpty == false {
            let state = queue.removeFirst()

            if visited.contains(state) { continue }
            visited.insert(state)

            if state.depth >= maxDepth { continue }

            for rule in rules {
                if state.surface.hasSuffix(rule.kanaIn) == false { continue }

                if let grammar = state.grammar,
                   rule.rulesIn.contains(grammar) == false {
                    continue
                }

                let stem = state.surface.dropLast(rule.kanaIn.count)
                let inflectedSurface = String(stem) + rule.kanaOut

                for nextGrammar in rule.rulesOut {
                    let nextState = InflectionState(surface: inflectedSurface, grammar: nextGrammar, depth: state.depth + 1)
                    if visited.contains(nextState) == false {
                        queue.append(nextState)
                        results.insert(inflectedSurface)
                    }
                }
            }
        }

        return results
    }
}
