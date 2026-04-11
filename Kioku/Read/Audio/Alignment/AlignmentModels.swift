// AlignmentModels.swift
// Core data types for the on-device lyric alignment pipeline.
// Mirrors the WhisperKitAlign package types but lives directly in the
// Kioku target so no package dependency is required.

import Foundation

// A single segment as returned by any transcription backend.
struct AlignmentSegment {
    let text: String
    let start: Double  // seconds
    let end: Double    // seconds
}

// One subtitle entry: the original input line plus its aligned timestamps.
struct AlignedLine {
    let text: String
    let start: Double  // seconds
    let end: Double    // seconds
}
