import Foundation

// One sub-cue checkpoint anchoring a character/mora group to a playback time.
// Stored alongside cues for an audio attachment; absence = no karaoke data, falls back to
// Sentence-level highlighting regardless of the user's granularity setting.
nonisolated struct CueCharTiming: Codable, Equatable {
    var timeMs: Int
    var charOffsetInCue: Int
    var charLength: Int
    // The aligner's 0...1 confidence that the audio sounds like this checkpoint's text
    // (AlignedToken.confidence); nil for cues from SRT import or transcription, and for notes
    // aligned before it was kept. Low values draw a squiggle under the text (AlignmentStruggleSpans).
    var confidence: Float? = nil
}

// Transient index-keyed binder output: all checkpoints for an attachment keyed by SubtitleCue.index
// (1-based). This is what TextGridBinder produces and the legacy on-disk sidecar held; checkpoints
// are no longer stored or threaded in this shape — they are folded into each cue via
// applyingCheckpoints(_:) immediately after binding.
typealias CueCharTimings = [Int: [CueCharTiming]]

nonisolated extension Array where Element == SubtitleCue {
    // Folds index-keyed binder output into each cue's inline `checkpoints`, matching on SubtitleCue.index.
    // Cues with no entry in `timings` keep empty checkpoints. The single seam between the binder's
    // natural index-keyed result and the unified one-cue model.
    func applyingCheckpoints(_ timings: CueCharTimings) -> [SubtitleCue] {
        map { cue in
            var updated = cue
            updated.checkpoints = timings[cue.index] ?? []
            return updated
        }
    }
}
