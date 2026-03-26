import Foundation
import Combine

struct Note: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var content: String
    var segments: [SegmentRange]?
    var createdAt: Date
    var modifiedAt: Date
    // Non-nil when the note was created from a subtitle import with audio; references
    // files managed by NotesAudioStore.
    var audioAttachmentID: UUID?
    // User-selected furigana overrides keyed by UTF-16 segment location.
    // These are semantic choices, not rendering artifacts, and must survive export/import.
    var readingOverrides: [Int: String]?

    // Creates a note value with optional defaults for new-note workflows.
    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        segments: [SegmentRange]? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        audioAttachmentID: UUID? = nil,
        readingOverrides: [Int: String]? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.segments = segments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.audioAttachmentID = audioAttachmentID
        self.readingOverrides = readingOverrides
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
        audioAttachmentID = try container.decodeIfPresent(UUID.self, forKey: .audioAttachmentID)
        readingOverrides = try container.decodeIfPresent([Int: String].self, forKey: .readingOverrides)
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
        try container.encodeIfPresent(audioAttachmentID, forKey: .audioAttachmentID)
        try container.encodeIfPresent(readingOverrides, forKey: .readingOverrides)
    }
}
