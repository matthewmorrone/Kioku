import Foundation
import Combine

struct Note: Identifiable, Codable, Equatable, Hashable {
    static let currentSchemaVersion = 1

    var id: UUID
    var title: String
    var content: String
    // Segments store the canonical segmentation with furigana annotations.
    // Each SegmentRange may carry [FuriganaAnnotation] covering kanji runs within it.
    var segments: [SegmentRange]?
    var createdAt: Date
    var modifiedAt: Date
    // Non-nil when the note was created from a subtitle import with audio; references
    // files managed by NotesAudioStore.
    var audioAttachmentID: UUID?

    // Creates a note value with optional defaults for new-note workflows.
    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        segments: [SegmentRange]? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        audioAttachmentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.segments = segments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.audioAttachmentID = audioAttachmentID
    }
}
