import Foundation

// Which character of a breakdown line is being sung at a moment of the song, from the line's cue and
// its alignment checkpoints, so listen-along can follow a line's sung clip word by word the way
// it follows the synthesized sentence. Pure and `nonisolated`, like SongWordClipLocator.
nonisolated enum SongSungCharacter {
    // The UTF-16 offset in `line` of the last checkpoint sung at or before `timeMs`; nil before the
    // line's first checkpoint, when the cue has none, or when the line isn't the cue's text (nor
    // found inside it).
    static func offset(atMs timeMs: Int, in cue: SubtitleCue, line: String) -> Int? {
        guard let sung = cue.checkpoints.filter({ $0.timeMs <= timeMs }).max(by: { $0.timeMs < $1.timeMs }) else {
            return nil
        }
        let lineStart: Int
        if cue.text == line {
            lineStart = 0
        } else {
            let found = (cue.text as NSString).range(of: line)
            guard found.location != NSNotFound else { return nil }
            lineStart = found.location
        }
        let offset = sung.charOffsetInCue - lineStart
        return offset >= 0 && offset < (line as NSString).length ? offset : nil
    }
}
