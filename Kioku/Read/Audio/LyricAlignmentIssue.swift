import Foundation
import LyricAlignment

// One place a finished alignment says the note's lyrics don't match the singing (the aligner's
// AlignmentMismatch, in cue milliseconds). `anchorStartMs` names the cue that new lyrics for the
// spot go next to (by its start, which survives ♪ markers renumbering the cues):
// before it for singing with no line, after it for a stretched line or singing at the song's end.
// `lineText` is the stretched line, shown in the row. Lives only for the session: the list is shown
// when an alignment finishes and from the lyrics card's banner until it is reviewed or the song is
// aligned again.
nonisolated struct LyricAlignmentIssue: Identifiable, Hashable {
    let id: Int
    let kind: AlignmentMismatchKind
    let startMs: Int
    let endMs: Int
    let lineText: String?
    let anchorStartMs: Int?
    let insertsBeforeAnchor: Bool
}
