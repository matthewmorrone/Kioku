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
    // True when `segments` reflect a genuine user customization (manual merge/split, a pinned
    // reading, or an applied AI correction) rather than the segmenter's own output. Import
    // precompute persists the *computed* segmentation, so `segments != nil` alone can't tell the
    // two apart — this flag does, and it gates the read screen's reset button. Optional so notes
    // written before this field existed decode as nil; `hasUserEditedSegments` treats nil as false.
    var segmentsAreUserEdited: Bool?
    var createdAt: Date
    var modifiedAt: Date
    // Non-nil when the note was created from a subtitle import with audio; references
    // files managed by NotesAudioStore.
    var audioAttachmentID: UUID?

    // Whether the persisted segmentation/readings are a user customization (nil legacy = no).
    var hasUserEditedSegments: Bool {
        segmentsAreUserEdited ?? false
    }

    // Creates a note value with optional defaults for new-note workflows.
    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        segments: [SegmentRange]? = nil,
        segmentsAreUserEdited: Bool? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        audioAttachmentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.segments = segments
        self.segmentsAreUserEdited = segmentsAreUserEdited
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.audioAttachmentID = audioAttachmentID
    }
}
