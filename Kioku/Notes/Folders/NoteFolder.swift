import Foundation

// A user-made group of notes. Folders are one level deep; a note belongs to at most one folder via
// `Note.folderID`, and a note with no folder lives in the Notes tab's top level. Pure data.
nonisolated struct NoteFolder: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
