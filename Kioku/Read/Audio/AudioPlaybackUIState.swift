import Foundation
import Observation

// Owns ReadView's audio-attachment playback state: the controller, the attached note's cues
// and karaoke highlight ranges, the live playback highlight override, and which attachment/cue
// is currently active. Extracted from ReadView's own @State so it reads as one unit.
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
    var isShowingLyricsView = false
    // Mirrors "playing, or paused mid-track" from the controller. ReadView can't observe the
    // controller's @Published values through this @Observable wrapper, so AudioCueHighlightObserver
    // writes this flag and the mini player's visibility reads it — stopping from a paused state
    // changes nothing else ReadView watches, and the mini player would otherwise stay on screen.
    var hasPlaybackProgress = false
    // Which version of the song is playing (mix / isolated vocals / instrumental), and whether a
    // switch is still building its file.
    var audioSource: LyricsAudioSource = .mix
    var isSwitchingAudioSource = false
}
