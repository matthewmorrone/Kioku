import Foundation

// KANJIDIC2 metadata for one kanji character — readings, English meanings, and learner metadata.
struct KanjiInfo {
    let literal: String
    let grade: Int?
    let strokeCount: Int?
    let jlptLevel: Int?
    let onReadings: [String]
    let kunReadings: [String]
    let meanings: [String]
}
