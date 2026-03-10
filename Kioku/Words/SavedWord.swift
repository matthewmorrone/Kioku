import Foundation

// Represents one saved word, optionally linked to the note where it was starred.
struct SavedWord: Codable, Hashable {
    let surface: String
    let sourceNoteID: UUID?
}
