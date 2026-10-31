import Foundation

// One proposed text replacement in a note (English → katakana, or a width fix), awaiting the
// user's review in TextConversionSheet.
struct TextConversion: Identifiable, Equatable {
    let id = UUID()
    // UTF-16 range of the replaced run in the note text the proposal was made against.
    let range: NSRange
    let original: String
    var replacement: String
    let source: TextConversionSource
    var isAccepted = true
}

// Where a proposal came from: a dictionary loanword, the English spelling rules, width
// normalization, or a Breakdown typo fix.
enum TextConversionSource: Equatable {
    case dictionary
    case rules
    case width
    // A typo the song's Breakdown flagged (SongLineFix).
    case breakdown
}

// A katakana-only dictionary form whose gloss is the English word being converted.
struct LoanwordCandidate: Equatable {
    let kana: String
    let frequency: Double
}
