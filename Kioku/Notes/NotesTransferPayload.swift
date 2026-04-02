import Foundation

nonisolated struct NotesTransferPayload: Codable {
    static let currentVersion = 2

    var version: Int
    var exportedAt: Date
    var notes: [Note]

    // Creates a versioned payload for note import and export workflows.
    init(version: Int = currentVersion, exportedAt: Date = Date(), notes: [Note]) {
        self.version = version
        self.exportedAt = exportedAt
        self.notes = notes
    }
}
