import Foundation

// Enumerates the four display modes that the kana chart can cycle through.
enum KanaRepresentation: CaseIterable {
    case hiragana
    case katakana
    case romaji
    case ipa

    var label: String {
        switch self {
            case .hiragana: return "Hiragana"
            case .katakana: return "Katakana"
            case .romaji:   return "Roumaji"
            case .ipa:      return "IPA"
        }
    }

    // Returns the next representation in the cycle.
    var next: KanaRepresentation {
        let all = KanaRepresentation.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }

    // Returns the previous representation in the cycle.
    var previous: KanaRepresentation {
        let all = KanaRepresentation.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx - 1 + all.count) % all.count]
    }
}
