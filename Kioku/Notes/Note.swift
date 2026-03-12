import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var segments: [SegmentRange]?
    var createdAt: Date
    var modifiedAt: Date

    // Creates a note value with optional defaults for new-note workflows.
    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        segments: [SegmentRange]? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.segments = segments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    // Decodes a note using the current segments-based schema.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NoteCodingKeys.self)
        let now = Date()

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        segments = try container.decodeIfPresent([SegmentRange].self, forKey: .segments)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }

    // Encodes a note with explicit segmentation and timestamp fields for stable transfer files.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: NoteCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(segments ?? [], forKey: .segments)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}
