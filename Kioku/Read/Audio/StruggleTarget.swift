import Foundation

// A squiggled checkpoint the user tapped: where its text sits in the note, the text itself, and the
// aligner's evidence for it (AlignmentStruggleSpans.target), shown in the squiggle popup and the
// correction editor.
struct StruggleTarget: Equatable {
    // UTF-16 range of the checkpoint's text in the note.
    let range: NSRange
    let text: String
    // Confidence, expected phonemes and what the model heard, as the popup prints them.
    let detail: String
}
