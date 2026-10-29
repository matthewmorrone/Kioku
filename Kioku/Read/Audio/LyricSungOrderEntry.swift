import Foundation

// One step of the order a song's lines seem to be sung in (the aligner's SungOrderEntry, in cue
// milliseconds): a note line's text, or, with `lineText` nil, a stretch of heard singing no note
// line explains. Feeds the alignment issue list's sung-order preview; session-only like the issues.
nonisolated struct LyricSungOrderEntry: Hashable {
    let startMs: Int
    let endMs: Int
    let lineText: String?
}
