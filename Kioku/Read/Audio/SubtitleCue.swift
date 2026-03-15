import Foundation

// Represents one subtitle cue from an SRT file, including its millisecond timing and
// the UTF-16 byte range it occupies in the assembled note content.
struct SubtitleCue: Codable, Equatable {
    // Sequential index as written in the SRT file.
    var index: Int
    // Playback start time in milliseconds.
    var startMs: Int
    // Playback end time in milliseconds.
    var endMs: Int
    // Raw subtitle text for this cue.
    var text: String
    // UTF-16 start offset of this cue's text within the assembled note content.
    var utf16Start: Int
    // UTF-16 end offset (exclusive) of this cue's text within the assembled note content.
    var utf16End: Int
}
