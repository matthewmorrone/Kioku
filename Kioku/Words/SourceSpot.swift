import Foundation

// The exact spot in a note that a word was starred from: the UTF-16 location of the tapped segment
// and its text. The text is what keeps the spot honest — after the note is edited, the spot only
// counts while those characters are still at that location (see NoteWordLocator).
nonisolated struct SourceSpot: Codable, Hashable {
    let noteID: UUID
    let location: Int
    let surface: String
}
