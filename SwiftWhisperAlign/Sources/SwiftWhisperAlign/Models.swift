// Models.swift
// Core data types for the forced-alignment pipeline.

import Foundation

public struct AlignmentInput {
    public let audioURL: URL
    public let lines: [String]
    public let language: String
    public init(audioURL: URL, lines: [String], language: String = "ja") {
        self.audioURL = audioURL; self.lines = lines; self.language = language
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
    public init(lines: [AlignedLine]) { self.lines = lines }
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
