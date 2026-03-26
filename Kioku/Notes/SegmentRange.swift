import Foundation

struct SegmentRange: Codable, Equatable, Hashable {
    var start: Int
    var end: Int
    var surface: String
    // Furigana annotations for this segment, stored as absolute UTF-16 offsets in the note text.
    // Nil for non-kanji segments. Multiple entries cover mixed kanji/kana surfaces like 生き方.
    var furigana: [FuriganaAnnotation]?

    // Creates a persisted UTF-16 segment range with surface text and optional furigana annotations.
    init(start: Int, end: Int, surface: String, furigana: [FuriganaAnnotation]? = nil) {
        self.start = start
        self.end = end
        self.surface = surface
        self.furigana = furigana
    }

    // Decodes with a fallback empty surface so legacy segments without the field still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        end = try container.decode(Int.self, forKey: .end)
        surface = try container.decodeIfPresent(String.self, forKey: .surface) ?? ""
        furigana = try container.decodeIfPresent([FuriganaAnnotation].self, forKey: .furigana)
    }
}
