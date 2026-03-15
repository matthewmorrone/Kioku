import Foundation

// Provides shared kana normalization helpers used by reading alignment and script-level matching.
enum KanaNormalizer {
    private static let furiganaAlignmentReplacements = loadFuriganaAlignmentReplacements()

    // Normalizes kana variants so furigana alignment treats equivalent spellings as interchangeable.
    static func normalizeForFuriganaAlignment(_ text: String) -> String {
        var normalized = text

        for (source, target) in furiganaAlignmentReplacements {
            normalized = normalized.replacingOccurrences(of: source, with: target)
        }

        return normalized
    }

    // Loads furigana-alignment replacement pairs from bundled JSON to keep normalization rules data-driven.
    private static func loadFuriganaAlignmentReplacements(
        bundle: Bundle = .main,
        resourceName: String = "kana_alignment_normalizations",
        fileExtension: String = "json"
    ) -> [(source: String, target: String)] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            print("Missing kana normalization file: \(resourceName).\(fileExtension)")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let replacements = try JSONDecoder().decode([String: String].self, from: data)
            return replacements.map { pair in
                (source: pair.key, target: pair.value)
            }
        } catch {
            print("Failed to decode kana normalization file: \(error)")
            return []
        }
    }
}
