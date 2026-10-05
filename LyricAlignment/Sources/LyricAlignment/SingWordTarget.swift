// SingWordTarget.swift
//
// One lyric word Sing mode listens for: its phoneme tokens and the song-time window it is
// expected in. Pure data; SingPhonemeScorer does the scoring.

import Foundation

public struct SingWordTarget: Sendable, Equatable {
    /// Caller's key for the word (the app uses its UTF-16 start in the note text).
    public let id: Int
    /// Indices into the phoneme model's label set, from SingPhonemeScorer.tokens(fromRomaji:).
    public let tokens: [Int]
    /// Song time the word starts and ends at, in seconds.
    public let startSec: Double
    public let endSec: Double
    /// How far before / after the aligned time the singer may land. Wider at a line's edges,
    /// where there is no neighbouring word to mistake for this one.
    public let leadSlackSec: Double
    public let tailSlackSec: Double
    public init(id: Int, tokens: [Int], startSec: Double, endSec: Double,
                leadSlackSec: Double = SingPhonemeScorer.leadSlackSec, tailSlackSec: Double = SingPhonemeScorer.tailSlackSec) {
        self.id = id; self.tokens = tokens; self.startSec = startSec; self.endSec = endSec
        self.leadSlackSec = leadSlackSec; self.tailSlackSec = tailSlackSec
    }
}
