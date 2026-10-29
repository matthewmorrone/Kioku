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
// normalization, a Breakdown typo fix, lyrics transcribed for an alignment issue, or the lyrics
// rearranged into the order they're sung.
enum TextConversionSource: Equatable {
    case dictionary
    case rules
    case width
    // A typo the song's Breakdown flagged (SongLineFix).
    case breakdown
    // Lyrics transcribed from a stretch of the song the note had none for (LyricAlignmentIssue).
    case transcription
    // The song's lyrics rearranged into the order they're sung (the sung-order preview).
    case sungOrder
}

// A katakana-only dictionary form whose gloss is the English word being converted.
struct LoanwordCandidate: Equatable {
    let kana: String
    let frequency: Double
}
