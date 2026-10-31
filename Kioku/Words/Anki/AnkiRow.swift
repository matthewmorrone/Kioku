import Foundation

// One Anki note: the word, its meaning, reading, the user's own note, and tags. Pure data.
nonisolated struct AnkiRow: Equatable, Sendable {
    let front: String
    let back: String
    let reading: String
    let notes: String
    let tags: [String]
}
