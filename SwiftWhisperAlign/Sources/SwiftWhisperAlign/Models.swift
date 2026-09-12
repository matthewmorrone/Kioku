// Models.swift
// Core data types for the forced-alignment pipeline.

import Foundation

public struct AlignmentInput {
    public let audioURL: URL
    public let lines: [String]
    /// One array per line: the line's romanization as spans that each cover a UTF-16 range of
    /// the line text. The aligner reads only the romaji; the ranges become karaoke checkpoints.
    public let romanization: [[RomanizedSpan]]
    public init(audioURL: URL, lines: [String], romanization: [[RomanizedSpan]]) {
        self.audioURL = audioURL; self.lines = lines; self.romanization = romanization
    }
}

/// A run of romaji (lowercase a–z) and the UTF-16 span of the source line it transcribes —
/// one kana, or one kanji run with its reading.
public struct RomanizedSpan: Sendable {
    public let romaji: String
    public let charOffsetUTF16: Int
    public let charLengthUTF16: Int
    public init(romaji: String, charOffsetUTF16: Int, charLengthUTF16: Int) {
        self.romaji = romaji; self.charOffsetUTF16 = charOffsetUTF16; self.charLengthUTF16 = charLengthUTF16
    }
}

/// A single segment as returned by WhisperKit's transcribe().
public struct TranscriptionSegment {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

/// One subtitle entry: original input line plus its aligned timestamps.
public struct AlignedLine {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct AlignmentResult {
    public let lines: [AlignedLine]
    /// Per-line sub-line checkpoints (one inner array per `lines` entry, same order). Each token's
    /// char offset/length is UTF-16 into that line, so it drops directly onto a `CueCharTiming`
    /// for the per-word/per-mora karaoke sweep. Empty (or empty inner arrays) → line-level only.
    public let lineTokens: [[AlignedToken]]
    public init(lines: [AlignedLine], lineTokens: [[AlignedToken]] = []) {
        self.lines = lines
        self.lineTokens = lineTokens
    }
}

/// One forced-aligned token within a single line: its DTW timestamp plus the
/// span of the *line* text it covers, expressed in UTF-16 units so it maps
/// directly onto Kioku's `CueCharTiming` checkpoints without re-tokenizing.
/// `start` is in seconds, already offset to the original audio timeline (the
/// window-relative time has had the window start added back).
public struct AlignedToken {
    public let start: Double
    public let charOffsetUTF16: Int
    public let charLengthUTF16: Int
    public init(start: Double, charOffsetUTF16: Int, charLengthUTF16: Int) {
        self.start = start
        self.charOffsetUTF16 = charOffsetUTF16
        self.charLengthUTF16 = charLengthUTF16
    }
}

/// Result of aligning a single line over an audio window: the line-level
/// start/end (for tightening cue boundaries) plus the per-token checkpoints
/// (for the word/character karaoke sweep).
public struct AlignedLineTokens {
    public let line: AlignedLine
    public let tokens: [AlignedToken]
    public init(line: AlignedLine, tokens: [AlignedToken]) {
        self.line = line
        self.tokens = tokens
    }
}
