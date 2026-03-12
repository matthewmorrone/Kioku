import Foundation

struct NotesTransferPayload: Codable {
    var version: Int
    var exportedAt: Date
    var notes: [Note]

    // Creates a versioned payload for note import and export workflows.
    init(version: Int = 2, exportedAt: Date = Date(), notes: [Note]) {
        self.version = version
        self.exportedAt = exportedAt
        self.notes = notes
    }

    // Decodes payload metadata while remaining compatible with legacy exports without exportedAt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesTransferPayloadCodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        notes = try container.decode([Note].self, forKey: .notes)
    }

    // Encodes payload metadata and notes for portable exports.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: NotesTransferPayloadCodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(notes, forKey: .notes)
    }
}