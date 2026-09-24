import Foundation

// Finds where one breakdown word is sung inside its line's cue, from the cue's per-character
// alignment checkpoints, so listen-along can play the singer's own voice for that word. Pure
// (cue text + checkpoints in, time range out) and `nonisolated` so the `nonisolated`
// SongListenScript can call it.
//
// Checkpoints mark onsets only: the word's start is the onset of the checkpoint covering its
// first character, and its end is the onset of the first checkpoint at or after its last
// character (the next sung sound), or the line's own end when the word closes the line.
nonisolated enum SongWordClipLocator {
    // A snippet shorter than this is a mis-bound checkpoint rather than a sung word.
    static let minimumDurationMs = 80
    // A span longer than this runs into an instrumental break inside the line; the snippet is
    // cut there rather than playing the break.
    static let maximumDurationMs = 2500

    // The sung time range of `surface` within `cue`, searching from UTF-16 offset `searchFrom`
    // first (so a word sung twice in a line maps to its occurrences in order) and then from the
    // top. Returns the range and the UTF-16 offset just past the word, for the next search. Nil
    // when the cue has no checkpoints, the surface isn't in the cue text (a dictionary-form
    // headword for an inflected sung form, or a word borrowed from a referenced line), or the
    // checkpoints don't bracket it.
    static func locate(
        _ surface: String,
        in cue: SubtitleCue,
        lineEndMs: Int,
        searchFrom: Int
    ) -> (startMs: Int, endMs: Int, nextSearchFrom: Int)? {
        guard surface.isEmpty == false, cue.checkpoints.isEmpty == false else { return nil }
        let text = cue.text as NSString
        let from = min(max(0, searchFrom), text.length)
        var found = text.range(of: surface, range: NSRange(location: from, length: text.length - from))
        if found.location == NSNotFound {
            found = text.range(of: surface)
        }
        guard found.location != NSNotFound else { return nil }

        let wordStart = found.location
        let wordEnd = found.location + found.length
        let checkpoints = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        guard let first = checkpoints.last(where: { $0.charOffsetInCue <= wordStart }),
              first.charOffsetInCue + max(1, first.charLength) > wordStart else { return nil }

        let startMs = first.timeMs
        let nextOnsetMs = checkpoints.first(where: { $0.charOffsetInCue >= wordEnd })?.timeMs ?? lineEndMs
        let endMs = min(nextOnsetMs, startMs + maximumDurationMs)
        guard endMs - startMs >= minimumDurationMs else { return nil }
        return (startMs, endMs, wordEnd)
    }
}
