import Foundation

// What a successful SongListenAudioService.renderAudio call hands back: the synthesized
// track plus one SubtitleCue per script segment (sentence, gist, word, definition), each
// stamped with its speech-only start/end offset within that track. Reused as-is by
// AudioPlaybackController — exactly the model the karaoke Read view already drives its
// text highlighting from — so the Listen sheet's transcript can highlight in sync with
// playback without inventing a second timing format. Own file per the repo's
// no-nested-types rule.
nonisolated struct SongListenRenderResult: Equatable, Sendable {
    let url: URL
    let cues: [SubtitleCue]
}
