import Foundation

struct NotesTransferPayload: Codable {
    var version: Int
    var notes: [Note]

    // Creates a versioned payload for note import and export workflows.
    init(version: Int = 1, notes: [Note]) {
        self.version = version
        self.notes = notes
    }
}