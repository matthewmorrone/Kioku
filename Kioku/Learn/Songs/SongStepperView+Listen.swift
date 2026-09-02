import Foundation
import SwiftUI

// Listen-along for SongStepperView: rendering the narrated track through SongListenStore,
// playing it back through the view's own scratch controller, and mapping the playhead back
// onto the cards so the line — and the exact clip / sentence / gist / word row — being
// spoken is highlighted in place. The toolbar headphones button plays every line in
// sequence; each card's play button plays just that line's stretch of the same track. Split
// out of SongStepperView to keep the view file within bounds; the state it drives lives on
// the view (internal for that reason).
extension SongStepperView {

    // Render state for this note, nil when no render was ever requested.
    private var listenRenderState: SongListenRenderState? {
        listenStore.renderStateByNoteID[note.id]
    }

    // What the toolbar button shows — see SongListenControlState.
    var listenControlState: SongListenControlState {
        if listenPlayback.isPlaying { return .playing }
        switch listenRenderState {
        case .rendering: return .rendering
        case .failed: return .failed
        case .ready, nil: return .idle
        }
    }

    // What a card's play button shows: a spinner while the narration track is being
    // generated, play once it exists, pause while this line is the one speaking. Nil
    // (hidden) while there's no breakdown to narrate or the render hasn't started / failed.
    func cardPlayState(for line: SongLine) -> SongLineCardPlayState? {
        guard hasBreakdown, isStreamingCards == false else { return nil }
        if listenPlayback.isPlaying, activeListenSegment?.lineIndex == line.index { return .playing }
        switch listenRenderState {
        case .rendering: return .loading
        case .ready: return .idle
        case .failed, nil: return nil
        }
    }

    // Starts generating the narration track as soon as a breakdown is on screen (and the
    // note's cues have been looked up, so the clip inputs are final), without playing it —
    // that's what turns the cards' spinners into play buttons. Idempotent per breakdown
    // version + clip inputs, so calling it on every row refresh is free once it's done.
    func prepareListenTrack() {
        guard didLoadNoteCues, hasBreakdown, isStreamingCards == false else { return }
        ensureListenRendered()
    }

    // The segment the track is currently speaking, or nil when not playing. Cues carry only
    // text and timing, so this rebuilds the script the render was made from (a pure function
    // of the breakdown + clip ranges) and pairs cues with steps by order; a count mismatch
    // (e.g. a cues sidecar from a different render) disables the row highlight rather than
    // lighting up the wrong text.
    var activeListenSegment: SongListenSegment? {
        guard isListening, listenPlayback.isPlaying, let cueIndex = listenPlayback.activeCueIndex,
              listenSegments.count == listenPlayback.cues.count,
              listenSegments.indices.contains(cueIndex) else { return nil }
        return listenSegments[cueIndex]
    }

    // Toolbar headphones: play the whole track in sequence. Resumes from wherever the
    // playhead is (a line played from its card leaves it at that line's end, so this
    // continues into the next line) and renders first if the track doesn't exist yet.
    func playAllListen() {
        isListening = true
        pendingPlayLineIndex = nil
        if loadedListenURL != nil {
            listenPlayback.play()
            return
        }
        ensureListenRendered()
        loadListenTrackIfReady()
    }

    // A card's play button: play just this line's clip + narration. Renders first if
    // needed, remembering the line so it plays as soon as the track is ready.
    func playListen(line: SongLine) {
        isListening = true
        if loadedListenURL != nil {
            pendingPlayLineIndex = nil
            playListenRange(forLineIndex: line.index)
            return
        }
        pendingPlayLineIndex = line.index
        ensureListenRendered()
        loadListenTrackIfReady()
    }

    // Card tap while its line is speaking, or the toolbar pause.
    func pauseListen() {
        listenPlayback.pause()
    }

    // Re-runs a failed render from the toolbar's warning button.
    func retryListenRender() {
        guard let breakdown = cachedBreakdown else { return }
        listenStore.retry(for: breakdown, sourceAudioURL: listenSourceAudioURL, lineRanges: lineRangesByIndex)
    }

    // Tears listen-along down (view disappearing, or a regenerate replacing the lines the
    // track narrates): remembers the playhead so the next play resumes, releases the player,
    // and drops the row highlight.
    func stopListening() {
        listenStore.recordPosition(listenPlayback.currentTimeMs, forNoteID: note.id)
        listenPlayback.unload()
        loadedListenURL = nil
        listenSegments = []
        pendingPlayLineIndex = nil
        isListening = false
    }

    // Loads a newly (or already) ready track into the scratch player, rebuilds the cue →
    // segment map, then plays: the pending line if a card asked for one, otherwise the
    // whole track from wherever it last left off. No-op if this URL is already loaded.
    func loadListenTrackIfReady() {
        guard isListening, let breakdown = cachedBreakdown,
              case .ready(let url) = listenRenderState,
              loadedListenURL != url else { return }
        loadedListenURL = url
        let cues = listenStore.cues(forNoteID: note.id)
        listenSegments = Self.listenSegments(for: breakdown, lineRanges: effectiveListenLineRanges)
        do {
            try listenPlayback.load(audioURL: url, cues: cues)
        } catch {
            // Loaded-but-unplayable is rare (e.g. the cached file was removed mid-session);
            // the toolbar's retry re-renders it.
            print("[SongStepperView] listen track load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        if let pending = pendingPlayLineIndex {
            pendingPlayLineIndex = nil
            playListenRange(forLineIndex: pending)
            return
        }
        let resumeMs = listenStore.lastPositionMs(forNoteID: note.id)
        if resumeMs > 0 {
            listenPlayback.seek(toMs: resumeMs)
        }
        listenPlayback.play()
    }

    // Plays the span of the track covering every cue that belongs to the line — the sung
    // clip (when spliced in), the sentence, the gist, and each word — stopping at its end.
    private func playListenRange(forLineIndex index: Int) {
        let cues = listenPlayback.cues
        guard listenSegments.count == cues.count else { return }
        var startMs: Int? = nil
        var endMs: Int? = nil
        for (i, segment) in listenSegments.enumerated() where segment.lineIndex == index {
            startMs = min(startMs ?? cues[i].startMs, cues[i].startMs)
            endMs = max(endMs ?? cues[i].endMs, cues[i].endMs)
        }
        guard let startMs, let endMs else { return }
        listenPlayback.playRange(startMs: startMs, endMs: endMs)
    }

    // Kicks off (or reuses) the render for the current breakdown and clip inputs.
    private func ensureListenRendered() {
        guard let breakdown = cachedBreakdown else { return }
        listenStore.ensureRendered(for: breakdown, sourceAudioURL: listenSourceAudioURL, lineRanges: lineRangesByIndex)
    }

    // One segment per cue the render produced, in track order: speech steps as-is, and each
    // sung clip as a sentence-kind segment carrying the line's text so the clip highlights
    // the Japanese row while it plays. Mirrors SongListenAudioService's cue emission exactly.
    private static func listenSegments(for breakdown: SongBreakdown, lineRanges: [Int: (startMs: Int, endMs: Int)]) -> [SongListenSegment] {
        let originalByIndex = Dictionary(breakdown.lines.map { ($0.index, $0.original) }, uniquingKeysWith: { first, _ in first })
        return SongListenScript.build(from: breakdown, lineRanges: lineRanges).map { step in
            switch step {
            case .speech(let segment):
                return segment
            case .clip(let lineIndex, _, _):
                return SongListenSegment(lineIndex: lineIndex, kind: .sentence, text: originalByIndex[lineIndex] ?? "", language: .japanese)
            }
        }
    }

    // The clip ranges the render actually used — none without an audio file, matching
    // SongListenAudioService's own `effectiveRanges`.
    private var effectiveListenLineRanges: [Int: (startMs: Int, endMs: Int)] {
        listenSourceAudioURL != nil ? lineRangesByIndex : [:]
    }

    // The note's own audio file, spliced in before each line when its cue range is known.
    var listenSourceAudioURL: URL? {
        note.audioAttachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) }
    }
}
