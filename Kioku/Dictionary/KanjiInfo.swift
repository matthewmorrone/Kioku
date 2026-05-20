import Foundation

// KANJIDIC2 metadata for one kanji character — readings, English meanings, and learner metadata.
// Identifiable via `literal` so SwiftUI `.sheet(item:)` can present one kanji at a time.
struct KanjiInfo: Identifiable {
    var id: String { literal }
    let literal: String
    let grade: Int?
    let strokeCount: Int?
    let jlptLevel: Int?
    // The traditional radical number (1–214) the kanji is filed under in the Kangxi system.
    let radical: Int?
    // Mainichi Shimbun newspaper frequency rank, 1 = most common; KANJIDIC2 only ships this for ~2500 kanji.
    let freqMainichi: Int?
    let onReadings: [String]
    let kunReadings: [String]
    let meanings: [String]
}
