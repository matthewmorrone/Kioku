import Foundation

// What a correction pass started from, so Cancel can put the note and its timed lyrics back:
// the cues as aligned, and every replacement made since (note range after the edit, the text it
// replaced).
struct AlignmentCorrectionSession {
    let cues: [SubtitleCue]
    var edits: [(range: NSRange, original: String)] = []
}
