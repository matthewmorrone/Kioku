import Foundation

// The resolved study content for one saved word: the headword spellings and the meanings its
// selected senses/glosses pick. Pure data; WordCardContentResolver builds it.
nonisolated struct WordCardContent: Equatable, Sendable {
    let surface: String
    let kanji: String?
    let kana: String?
    // One entry per selected sense/gloss, falling back to the entry's first gloss.
    let meanings: [String]
}
