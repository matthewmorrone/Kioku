import Foundation
import SwiftUI

// Listen-along for SongStepperView: playing a breakdown's script live through
// SongLiveListenController and mapping its published state back onto the cards so the line —
// and the exact clip / sentence / gist / word row — being spoken is highlighted in place. The
// toolbar headphones button plays every line in sequence; each card's play button plays just
// that line's stretch. Split out of SongStepperView to keep the view file within bounds; the
// state it drives lives on the view (internal for that reason).
extension SongStepperView {

    // What the toolbar button shows — see SongListenControlState.
    var listenControlState: SongListenControlState {
        if liveListen.isPlaying { return .playing }
        if liveListen.lastError != nil { return .failed }
        return .idle
    }

    // What a card's audio button shows: play, or pause while this line is the one speaking.
    // Nil (hidden) while there's no breakdown to narrate.
    func cardPlayState(for line: SongLine) -> SongLineCardPlayState? {
        guard hasBreakdown, isStreamingCards == false else { return nil }
        if liveListen.isPlaying, liveListen.currentSegment?.lineIndex == line.index { return .playing }
        return .idle
    }

    // The segment the controller is speaking — or, while paused, the one it stopped on. That
    // highlight is how the place is kept: resuming restarts from the start of this segment
    // (re-saying a word is fine) rather than mid-utterance.
    var activeListenSegment: SongListenSegment? {
        liveListen.currentSegment
    }

    // Fractional progress (0...1) through the currently-active `.sentence` segment — used by
    // SongLineCard to estimate which of the Read tab's segmented words is being spoken right
    // now. Driven by AVSpeechSynthesizer's live per-character callback (see
    // SongLiveListenController.handleWillSpeak), not an interpolated guess.
    var listenSentenceProgress: Double? {
        liveListen.sentenceProgress
    }

    // Toolbar headphones: play the whole script in sequence, resuming from wherever it last
    // stopped.
    func playAllListen() {
        isListening = true
        configureLiveListen()
        liveListen.play()
    }

    // A card's play button: play just this line's clip + narration.
    func playListen(line: SongLine) {
        isListening = true
        configureLiveListen()
        liveListen.playLine(line.index)
    }

    // Card tap while its line is speaking, or the toolbar pause.
    func pauseListen() {
        liveListen.pause()
    }

    // Retries after a voice-unavailable / session-activation failure.
    func retryListenRender() {
        configureLiveListen()
        liveListen.play()
    }

    // Tears listen-along down (view disappearing, or a regenerate replacing the lines the
    // script narrates): stops playback, rewinds, and releases the audio session.
    func stopListening() {
        liveListen.stop()
        isListening = false
    }

    // Loads (or reloads, if the breakdown/clip inputs changed) the current breakdown's script
    // into the controller. Safe to call on every play/pause tap, or speculatively before one —
    // SongLiveListenController no-ops when the script and source are unchanged from what it
    // already has, and does its expensive one-time setup (opening the note's audio file,
    // resolving voices) in the background rather than on this call. SongStepperView also calls
    // this from `.onAppear`/once `noteCues` loads, well before any tap, so that background
    // work has already finished by the time the user actually presses play.
    func configureLiveListen() {
        guard let breakdown = cachedBreakdown else { return }
        let ranges = effectiveListenLineRanges
        let steps = SongListenScript.build(from: breakdown, lineRanges: ranges)
        let originalByIndex = Dictionary(breakdown.lines.map { ($0.index, $0.original) }, uniquingKeysWith: { first, _ in first })
        liveListen.configure(steps: steps, sourceAudioURL: listenSourceAudioURL, originalByLineIndex: originalByIndex)
    }

    // The clip ranges to actually splice in — none without an audio file.
    private var effectiveListenLineRanges: [Int: (startMs: Int, endMs: Int)] {
        listenSourceAudioURL != nil ? lineRangesByIndex : [:]
    }

    // The note's own audio file, spliced in before each line when its cue range is known.
    var listenSourceAudioURL: URL? {
        note.audioAttachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) }
    }
}
