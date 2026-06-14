import Foundation

// Represents one timed line of text (SRT cue, or a TextGrid-derived line) with millisecond timing
// and its optional per-character karaoke checkpoints. UTF-16 offsets into note content are
// intentionally not stored here — they are resolved dynamically from the live note text at playback
// time so that any edits to the note content never silently break highlighting. `checkpoints` is the
// per-cue sub-line timing, carried with the cue so there is one model and one file per attachment.
// nonisolated so the value type and its Equatable/Codable conformances stay usable from the detached
// bulk-import task.
nonisolated struct SubtitleCue: Codable, Equatable {
    // Sequential index as written in the SRT file.
    var index: Int
    // Playback start time in milliseconds.
    var startMs: Int
    // Playback end time in milliseconds.
    var endMs: Int
    // Raw subtitle text for this cue.
    var text: String
    // Per-character/word karaoke checkpoints for this cue. Empty = no sub-line timing (plain SRT);
    // the renderer falls back to whole-cue (Sentence) highlighting.
    var checkpoints: [CueCharTiming] = []
}
