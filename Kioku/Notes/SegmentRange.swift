import Foundation

// Persisted segmentation unit for a note. Segments are order-only: concatenating all
// segment.surface values in array order must equal the note's content. This replaces
// start/end offsets so that text edits preserve customizations in regions whose surfaces
// still match the new content (see reconcileSegments).
nonisolated struct SegmentRange: Codable, Equatable, Hashable {
    static let currentSchemaVersion = 2

    var surface: String
    // Furigana annotations within this segment, using UTF-16 offsets relative to `surface`.
    // Nil for non-kanji segments. Multiple entries cover mixed kanji/kana surfaces like 生き方.
    var furigana: [FuriganaAnnotation]?
    // The dictionary entry the user picked for this segment when its form is several words at once
    // (いった → 言う, not 行く). Nil when nothing was picked. Only honoured while the entry is still
    // one of the segment's possibilities (Lexicon.lookupCandidates), so a stale pick is ignored.
    var chosenEntryID: Int64?

    init(surface: String, furigana: [FuriganaAnnotation]? = nil, chosenEntryID: Int64? = nil) {
        self.surface = surface
        self.furigana = furigana
        self.chosenEntryID = chosenEntryID
    }
}
