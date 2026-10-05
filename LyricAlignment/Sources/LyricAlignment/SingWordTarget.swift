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
    public init(id: Int, tokens: [Int], startSec: Double, endSec: Double) {
        self.id = id; self.tokens = tokens; self.startSec = startSec; self.endSec = endSec
    }
}
