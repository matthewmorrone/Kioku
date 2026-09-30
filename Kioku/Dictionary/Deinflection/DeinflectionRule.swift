import Foundation

// Describes one deinflection transition from inflected suffix to base-form suffix.
nonisolated struct DeinflectionRule: Decodable {
    let kanaIn: String
    let kanaOut: String
    let rulesIn: [String]
    let rulesOut: [String]
    // The separate word this rule folds into its neighbour, in dictionary form, when it is one:
    // でゆく → で folds ゆく, きながら → く folds ながら, ちゃう → てしまう folds しまう. Segmentation keeps the
    // phrase one word; the lookup sheet names the folded word beside the lemma (see
    // Deinflector.helperWords) so it is never silently dropped.
    let helper: String?
}


