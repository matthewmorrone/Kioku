import Foundation

// Represents one subtitle cue from an SRT file with millisecond timing.
// UTF-16 offsets into note content are intentionally not stored here — they are
// resolved dynamically from the live note text at playback time so that any edits
// to the note content never silently break highlighting.
struct SubtitleCue: Codable, Equatable {
    // Sequential index as written in the SRT file.
    var index: Int
    // Playback start time in milliseconds.
    var startMs: Int
    // Playback end time in milliseconds.
    var endMs: Int
    // Raw subtitle text for this cue.
    var text: String
}
