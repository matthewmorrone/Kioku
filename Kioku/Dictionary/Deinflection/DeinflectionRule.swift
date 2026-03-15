import Foundation

// Describes one deinflection transition from inflected suffix to base-form suffix.
struct DeinflectionRule: Decodable {
    let kanaIn: String
    let kanaOut: String
    let rulesIn: [String]
    let rulesOut: [String]
}



