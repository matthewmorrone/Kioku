// SingWordTarget.swift
//
// One lyric word Sing mode listens for: its phoneme tokens and where in the song it begins.
// Pure data; SingPhonemeScorer does the scoring. Words are graded in lyric order, never against
// a time window: the start time only says where to resume after the singer seeks.

import Foundation

public struct SingWordTarget: Sendable, Equatable {
    /// Caller's key for the word (the app uses its UTF-16 start in the note text).
    public let id: Int
    /// Indices into the phoneme model's label set, from SingPhonemeScorer.tokens(fromRomaji:).
    public let tokens: [Int]
    /// Song time the word starts at, in seconds.
    public let startSec: Double
    public init(id: Int, tokens: [Int], startSec: Double) {
        self.id = id; self.tokens = tokens; self.startSec = startSec
    }
}
