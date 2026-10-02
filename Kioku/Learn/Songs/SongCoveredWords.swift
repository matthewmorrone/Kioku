import Foundation

// The Breakdown option "Repeat Earlier Words": when it's off, a word whose written form already
// came up earlier in the song (on an earlier line, or earlier in the same line) is hidden from
// that line's card and skipped by listen-along. Lines themselves are never dropped — a line whose
// every word was covered before still plays its clip and gist. One rule, used by both the cards
// and SongListenScript, so what is shown and what is spoken can't disagree.
nonisolated enum SongCoveredWords {
    // Each line's words with the already-covered ones removed, keyed by line index, walking the
    // lines in song order. `words` supplies a line's displayed words (its own, or a "= line N"
    // repeat's borrowed ones — SongListenScript.effectiveWords).
    static func uncoveredWords(in lines: [SongLine], words: (SongLine) -> [SongWord]) -> [Int: [SongWord]] {
        var seen = Set<String>()
        var result: [Int: [SongWord]] = [:]
        for line in lines {
            result[line.index] = words(line).filter { word in
                seen.insert(word.surface.trimmingCharacters(in: .whitespacesAndNewlines)).inserted
            }
        }
        return result
    }
}
