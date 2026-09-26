import Foundation

// The inputs of the note-vs-default comparison (ReadView.changesFromDefault): when any of them
// changes, ReadView recomputes differsFromDefault.
struct DefaultComparisonKey: Hashable {
    let text: String
    let segmentRanges: [Range<String.Index>]
    let furigana: [Int: String]
    let segmenterRevision: Int
    let resourcesReady: Bool
    let isEditing: Bool
}
