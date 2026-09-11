import Foundation
import Observation

// Owns ReadView's audio-attachment playback state: the controller, the attached note's cues
// and karaoke highlight ranges, the live playback highlight override, and which attachment/cue
// is currently active. Extracted from ReadView's own @State — see LLMCorrectionUIState for the
// same rationale applied to the LLM-correction feature.
@Observable
final class AudioPlaybackUIState {
    var audioController = AudioPlaybackController()
    // Cues carry their per-cue karaoke checkpoints inline (cue.checkpoints); there is no separate
    // timings state to keep in sync.
    var audioAttachmentCues: [SubtitleCue] = []
    var audioAttachmentHighlightRanges: [NSRange?] = []
    var playbackHighlightRangeOverride: NSRange?
    // Clears jumpToPendingScrollSurfaceIfReady's playbackHighlightRangeOverride borrow a few
    // seconds after landing, so a "jump to this word" highlight fades rather than sitting
    // indefinitely as if audio were still playing.
    var pendingScrollHighlightClearTask: Task<Void, Never>?
    var activePlaybackCueIndex: Int? = nil
    var activeAudioAttachmentID: UUID? = nil
    // True while the lyric view is playing the isolated vocal stem instead of the original mix
    // (the "Vocals/Mix" toggle next to Re-align). ReadView swaps the AudioPlaybackController's
    // source in onChange; reset to false whenever the audio source could change underneath it
    // (attachment switch, re-align that regenerates the stem).
    var isListeningToStem = false
    var isShowingLyricsView = false
}
