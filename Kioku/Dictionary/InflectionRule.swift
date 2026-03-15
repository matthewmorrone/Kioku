import Foundation

// Describes one inflection transition from lemma suffix to inflected suffix.
struct InflectionRule: Decodable {
    let kanaIn: String
    let kanaOut: String
    let rulesIn: [String]
    let rulesOut: [String]
}
