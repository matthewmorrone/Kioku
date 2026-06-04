import Foundation

// Organises kana entries into a named row for the gojūon chart.
// Five slots correspond to the vowels a, i, u, e, o — nil means the cell is empty.
struct KanaRow {
    let consonant: String
    let entries: [KanaEntry?]
}
