import Foundation

// Describes one deinflection transition from inflected suffix to base-form suffix.
nonisolated struct DeinflectionRule: Decodable {
    let kanaIn: String
    let kanaOut: String
    let rulesIn: [String]
    let rulesOut: [String]
    // The separate word this rule glues onto its neighbour, when it is one (でゆく → で: "ゆく").
    // kanaIn ends with it. The segmenter shows it as a word of its own (see Deinflector.helperWordOffsets).
    let helper: String?
}


