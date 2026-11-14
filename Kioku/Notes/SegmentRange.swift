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
    // True for a stretch a text edit changed: kept as one raw segment while the user types (no
    // segmenter runs in edit mode), and segmented with the whole text's context the next time the
    // note is shown. Nil otherwise.
    var needsSegmentation: Bool?
    // True when the user set this segment's furigana themselves (the lookup sheet's reading
    // picker), as opposed to a computed default. A merge keeps a pinned reading instead of
    // letting the merged word's dictionary reading replace it. Nil otherwise.
    var readingPinned: Bool?

    init(
        surface: String,
        furigana: [FuriganaAnnotation]? = nil,
        chosenEntryID: Int64? = nil,
        needsSegmentation: Bool? = nil,
        readingPinned: Bool? = nil
    ) {
        self.surface = surface
        self.furigana = furigana
        self.chosenEntryID = chosenEntryID
        self.needsSegmentation = needsSegmentation
        self.readingPinned = readingPinned
    }

    // Reconstructs a segment's full reading (kanji-run readings interleaved with its own literal
    // kana) from its persisted furigana annotations, whose start/end are UTF-16 offsets relative
    // to the segment's own surface. Empty when the segment has no furigana (kana-only segments,
    // or a kanji segment whose reading was never computed).
    var reconstructedReading: String {
        guard let furigana = furigana, furigana.isEmpty == false else { return "" }
        let surface = self.surface

        var reading = ""
        var cursor = surface.startIndex
        for annotation in furigana.sorted(by: { $0.start < $1.start }) {
            let start = String.Index(utf16Offset: annotation.start, in: surface)
            let end = String.Index(utf16Offset: annotation.end, in: surface)
            guard start >= cursor, end <= surface.endIndex, start <= end else { continue }
            if cursor < start {
                reading += surface[cursor..<start]
            }
            reading += annotation.reading
            cursor = end
        }
        if cursor < surface.endIndex {
            reading += surface[cursor...]
        }
        return reading
    }

    // Whether every segment is a finished segmentation, i.e. none is an edited stretch still
    // waiting for the segmenter. Persisted segments are only used as they are when this holds.
    static func isFullySegmented(_ segments: [SegmentRange]) -> Bool {
        segments.allSatisfy { $0.needsSegmentation != true }
    }
}
