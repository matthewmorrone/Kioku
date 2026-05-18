import Foundation

// One sub-cue checkpoint anchoring a character/mora group to a playback time.
// Stored alongside cues for an audio attachment; absence = no karaoke data, falls back to
// Sentence-level highlighting regardless of the user's granularity setting.
struct CueCharTiming: Codable, Equatable {
    var timeMs: Int
    var charOffsetInCue: Int
    var charLength: Int
}

// All checkpoints for a single audio attachment, keyed by SubtitleCue.index (1-based).
// Empty / missing key = that cue has no karaoke data; renderer falls back to whole-cue highlight.
typealias CueCharTimings = [Int: [CueCharTiming]]
