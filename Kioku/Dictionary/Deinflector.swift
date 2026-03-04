import Foundation

// Generates deinflected dictionary candidate surfaces using rule-based state transitions.
final class Deinflector {

    private let rules: [DeinflectionRule]
    private let maxDepth = 4

    // Stores deinflection rules used by candidate generation.
    init(rules: [DeinflectionRule]) {
        self.rules = rules.sorted { lhs, rhs in
            lhs.kanaIn.count > rhs.kanaIn.count
        }
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
    convenience init(jsonFileURL: URL) throws {
        let rules = try Self.loadRules(from: jsonFileURL)
        self.init(rules: rules)
    }

    // Builds a deinflector from grouped-rule JSON in the app bundle.
    convenience init(
        bundle: Bundle = .main,
        resourceName: String = "deinflection",
        fileExtension: String = "json"
    ) throws {
        let rules = try Self.loadRules(bundle: bundle, resourceName: resourceName, fileExtension: fileExtension)
        self.init(rules: rules)
    }

    // Performs BFS over deinflection states to produce candidate dictionary surfaces.
    func generateCandidates(for surface: String) -> Set<String> {

        var results: Set<String> = [surface]
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
}
