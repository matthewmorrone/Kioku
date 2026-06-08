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

    init(surface: String, furigana: [FuriganaAnnotation]? = nil) {
        self.surface = surface
        self.furigana = furigana
    }
}
