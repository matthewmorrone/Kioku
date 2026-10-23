import Foundation

// When a lyric word counts as sung, for everything that follows the song word by word: the lyrics
// card's word bubbles and the full-screen word view. One rule, so a word's bubble and its turn in
// the word view arrive together.
enum LyricWordTiming {
    // How long before its cue ends a line's last words are brought forward to, at the latest, so a
    // word timed at the line's very end (or past it, from a late alignment) still gets its moment
    // before the next line takes over.
    static let leadMs = 400

    // The latest a cue's words may start: leadMs before the cue ends, and never before the cue
    // starts — a line shorter than that has every word start with it.
    static func deadlineMs(for cue: SubtitleCue) -> Int {
        max(cue.startMs, cue.endMs - leadMs)
    }

    // When the word at `localOffset` (UTF-16, from the start of the cue's span in the note) is sung:
    // the first karaoke checkpoint reaching its first character, else the cue's last checkpoint,
    // else its share of the span — but no later than deadlineMs. `checkpoints` must be sorted by
    // charOffsetInCue (sortedCheckpoints), so callers sort once per cue rather than per word.
    static func startMs(localOffset: Int, spanLength: Int, cue: SubtitleCue, checkpoints: [CueCharTiming]) -> Int {
        let sungMs: Int
        if let hit = checkpoints.first(where: { $0.charOffsetInCue + max($0.charLength, 1) > localOffset }) {
            sungMs = hit.timeMs
        } else if let last = checkpoints.last {
            sungMs = last.timeMs
        } else {
            sungMs = cue.startMs + (cue.endMs - cue.startMs) * max(0, localOffset) / max(1, spanLength)
        }
        return min(sungMs, deadlineMs(for: cue))
    }

    // The cue's checkpoints in text order, the form startMs expects.
    static func sortedCheckpoints(_ cue: SubtitleCue) -> [CueCharTiming] {
        cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
    }
}
