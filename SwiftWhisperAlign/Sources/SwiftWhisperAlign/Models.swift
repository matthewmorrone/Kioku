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
