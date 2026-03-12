import Foundation

struct NotesRuntimeSegmentationSnapshot: Equatable {
    let content: String
    let segments: [SegmentRange]
}
