import Foundation
import SwiftUI

// Listen-along for SongStepperView: rendering the narrated track through SongListenStore,
// playing it back through the view's own scratch controller, and mapping the playhead back
// onto the cards so the line — and the exact sentence / gist / word row — being spoken is
// highlighted in place. Split out of SongStepperView to keep the view file within bounds;
// the state it drives lives on the view (internal for that reason).
extension SongStepperView {

    // The segment the track is currently speaking, or nil when not playing. Cues carry only
    // text and timing, so this rebuilds the script the render was made from (a pure function
    // of the breakdown + clip ranges) and pairs cues with speech steps by order; a count
    // mismatch (e.g. a cues sidecar from a different render) disables the row highlight
    // rather than lighting up the wrong text.
    var activeListenSegment: SongListenSegment? {
        guard isListening, let cueIndex = listenPlayback.activeCueIndex,
              listenSpeechSegments.count == listenPlayback.cues.count,
              listenSpeechSegments.indices.contains(cueIndex) else { return nil }
        return listenSpeechSegments[cueIndex]
    }

    // Turns listen-along on: kicks off (or reuses) the render and loads it if it's already
    // done. Safe to call again while rendering.
    func startListening() {
        guard let breakdown = cachedBreakdown else { return }
        isListening = true
        listenStore.ensureRendered(for: breakdown, sourceAudioURL: listenSourceAudioURL, lineRanges: lineRangesByIndex)
        loadListenTrackIfReady()
    }

    // Turns listen-along off: remembers the playhead so the next start resumes, releases the
    // player, and drops the row highlight.
    func stopListening() {
        listenStore.recordPosition(listenPlayback.currentTimeMs, forNoteID: note.id)
        listenPlayback.unload()
        loadedListenURL = nil
        listenSpeechSegments = []
        isListening = false
    }

    // Re-runs a failed render from the bar's Retry.
    func retryListenRender() {
        guard let breakdown = cachedBreakdown else { return }
        listenStore.retry(for: breakdown, sourceAudioURL: listenSourceAudioURL, lineRanges: lineRangesByIndex)
    }

    // Loads a newly (or already) ready track into the scratch player, rebuilds the cue →
    // segment map, resumes from wherever playback last left off, and starts playing. No-op
    // if this URL is already loaded (guards against redundant reloads from unrelated body
    // re-evaluations while the render state dictionary publishes).
    func loadListenTrackIfReady() {
        guard isListening, let breakdown = cachedBreakdown,
              case .ready(let url) = listenStore.renderState(forNoteID: note.id),
              loadedListenURL != url else { return }
        loadedListenURL = url
        let cues = listenStore.cues(forNoteID: note.id)
        listenSpeechSegments = SongListenScript.build(from: breakdown, lineRanges: lineRangesByIndex)
            .compactMap { step in
                if case .speech(let segment) = step { return segment }
                return nil
            }
        do {
            try listenPlayback.load(audioURL: url, cues: cues)
            let resumeMs = listenStore.lastPositionMs(forNoteID: note.id)
            if resumeMs > 0 {
                listenPlayback.seek(toMs: resumeMs)
            }
            listenPlayback.play()
        } catch {
            // Loaded-but-unplayable is rare (e.g. the cached file was removed mid-session);
            // the bar keeps its controls and the user can retry the render.
            print("[SongStepperView] listen track load failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // The note's own audio file, spliced in before each line when its cue range is known.
    var listenSourceAudioURL: URL? {
        note.audioAttachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) }
    }
}
