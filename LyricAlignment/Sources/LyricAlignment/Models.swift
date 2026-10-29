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
    /// Places where the lyric and the singing don't agree (see AlignmentMismatchDetector).
    public let mismatches: [AlignmentMismatch]
    /// The order the lines seem to be sung in, when there are mismatches and it isn't the note's
    /// own (see SungOrderDecoder); nil otherwise.
    public let sungOrder: [SungOrderEntry]?
    public init(lines: [AlignedLine], lineTokens: [[AlignedToken]] = [], mismatches: [AlignmentMismatch] = [], sungOrder: [SungOrderEntry]? = nil) {
        self.lines = lines
        self.lineTokens = lineTokens
        self.mismatches = mismatches
        self.sungOrder = sungOrder
    }
}

/// One step of the order a song's lines are actually sung in (SungOrderDecoder): a note line
/// (`lineIndex` into the aligned lyric) or, with `lineIndex` nil, a stretch of heard singing no
/// note line explains. Seconds.
public struct SungOrderEntry: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let lineIndex: Int?
    public init(start: Double, end: Double, lineIndex: Int?) {
        self.start = start; self.end = end; self.lineIndex = lineIndex
    }
}

/// What kind of disagreement between the lyric and the audio an AlignmentMismatch reports.
public enum AlignmentMismatchKind: String, Codable, Sendable {
    /// The vocal stem has singing where the alignment placed no line: lyrics missing from the
    /// note, or sung in a different order than the note has them.
    case unmatchedSinging
    /// One line was spread over far more time than its syllables can fill, so it is covering
    /// audio that belongs to other lyrics.
    case stretchedLine
}

/// One place an alignment doesn't fit: its kind, the stretch of audio (seconds), and a line index
/// in the aligned lyric: for a stretched line the line itself, for unmatched singing the line sung
/// right after it (nil when the singing runs to the song's end).
public struct AlignmentMismatch: Codable, Sendable, Equatable {
    public let kind: AlignmentMismatchKind
    public let start: Double
    public let end: Double
    public let lineIndex: Int?
    public init(kind: AlignmentMismatchKind, start: Double, end: Double, lineIndex: Int? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.lineIndex = lineIndex
    }
}

/// One forced-aligned token within a single line: its CTC onset time plus the
/// span of the *line* text it covers, expressed in UTF-16 units so it maps
/// directly onto Kioku's `CueCharTiming` checkpoints without re-tokenizing.
/// `start` is in seconds on the original audio timeline.
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
