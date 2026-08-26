import Foundation
import Combine
import SwiftUI

// Tracks in-flight/completed listen-along renders and last playback position per note, so
// dismissing the Listen sheet — mid-render or mid-playback — and reopening it picks up
// exactly where it left off instead of starting over. Mirrors SongBreakdownStore's
// generationStateByNoteID pattern: this state lives here, not in the sheet's local @State, so
// the sheet's view identity (and its .onDisappear teardown) never destroys progress.
//
// The audio file itself is already disk-cached by SongListenAudioService keyed on
// (noteID, sourceTextHash); what this store adds is the in-memory bits that cache can't hold:
// which render is currently running, its progress, the transcript cues for the active render,
// and the playhead position to resume from.
@MainActor
final class SongListenStore: ObservableObject {
    @Published private(set) var renderStateByNoteID: [UUID: SongListenRenderState] = [:]
    @Published private(set) var cuesByNoteID: [UUID: [SubtitleCue]] = [:]

    // Not published: read once when the sheet (re)loads the player, not on every tick — the
    // playback controller itself is what drives UI updates while a sheet is open.
    private var lastPositionMsByNoteID: [UUID: Int] = [:]

    // Which breakdown version `renderStateByNoteID[noteID]` currently reflects. A regenerated
    // breakdown gets a new `sourceTextHash`; comparing against it is what tells
    // `ensureRendered` to start a fresh render instead of reusing stale state left over from
    // the previous version.
    private var renderedHashByNoteID: [UUID: String] = [:]

    private var renderTasksByNoteID: [UUID: Task<Void, Never>] = [:]

    // Bumped on every startRender(for:) call. A render task only writes state guarded by the
    // generation it was started with, so a `retry()` that cancels an in-flight render and
    // immediately starts a replacement can't have the cancelled task's (asynchronous, delayed)
    // cleanup clobber the replacement's fresher state.
    private var renderGenerationByNoteID: [UUID: Int] = [:]

    // Current render/playback state for a note's Listen sheet. Defaults to "just started
    // rendering" for a note that's never been requested yet, so a first-time sheet appearance
    // (before `ensureRendered` has published anything) doesn't need a separate nil case.
    func renderState(forNoteID id: UUID) -> SongListenRenderState {
        renderStateByNoteID[id] ?? .rendering(progress: 0)
    }

    // Transcript cues for a note's most recent render. Empty until a render completes.
    func cues(forNoteID id: UUID) -> [SubtitleCue] {
        cuesByNoteID[id] ?? []
    }

    // Playhead position to resume from, in milliseconds. 0 (start of track) for a note that's
    // never been played or has never had its position recorded.
    func lastPositionMs(forNoteID id: UUID) -> Int {
        lastPositionMsByNoteID[id] ?? 0
    }

    // Called on sheet dismissal to remember where playback left off, so the next open resumes
    // instead of restarting at 0.
    func recordPosition(_ ms: Int, forNoteID id: UUID) {
        lastPositionMsByNoteID[id] = ms
    }

    // Starts a render for `breakdown` unless one is already running or done for this exact
    // breakdown version. Safe to call every time the sheet appears.
    func ensureRendered(for breakdown: SongBreakdown) {
        let noteID = breakdown.noteID
        if renderedHashByNoteID[noteID] == breakdown.sourceTextHash, renderStateByNoteID[noteID] != nil {
            return
        }
        startRender(for: breakdown)
    }

    // User-initiated retry after a failure. Always restarts, even if (unusually) the hash
    // hasn't changed since the failed attempt.
    func retry(for breakdown: SongBreakdown) {
        renderTasksByNoteID[breakdown.noteID]?.cancel()
        startRender(for: breakdown)
    }

    // Shared implementation behind `ensureRendered`/`retry`: bumps the generation counter,
    // publishes the "rendering" state immediately (so the sheet never shows stale state from a
    // prior note/version while the task spins up), and launches the render task. Also drops
    // any saved playback position if this is a genuinely new breakdown version (not just a
    // same-version retry) — a position saved against the old track's timing is meaningless
    // (and can seek past the end, or into unrelated text) once the track it was measured
    // against no longer exists.
    private func startRender(for breakdown: SongBreakdown) {
        let noteID = breakdown.noteID
        if renderedHashByNoteID[noteID] != breakdown.sourceTextHash {
            lastPositionMsByNoteID[noteID] = nil
        }
        let generation = (renderGenerationByNoteID[noteID] ?? 0) + 1
        renderGenerationByNoteID[noteID] = generation
        renderedHashByNoteID[noteID] = breakdown.sourceTextHash
        renderStateByNoteID[noteID] = .rendering(progress: 0)
        renderTasksByNoteID[noteID] = Task { [weak self] in
            await self?.render(breakdown, generation: generation)
        }
    }

    // Drives one render pass to completion (or failure/cancellation) and records the result.
    // A fresh SongListenAudioService per call — its AVSpeechSynthesizer can only drive one
    // render at a time, and two notes' renders can genuinely run concurrently here.
    private func render(_ breakdown: SongBreakdown, generation: Int) async {
        let noteID = breakdown.noteID
        do {
            let result = try await SongListenAudioService().renderAudio(for: breakdown) { [weak self] fraction in
                guard let self, self.renderGenerationByNoteID[noteID] == generation else { return }
                self.renderStateByNoteID[noteID] = .rendering(progress: fraction)
            }
            try Task.checkCancellation()
            guard renderGenerationByNoteID[noteID] == generation else { return }
            cuesByNoteID[noteID] = result.cues
            renderStateByNoteID[noteID] = .ready(url: result.url)
        } catch is CancellationError {
            // Superseded by a newer render (retry) — that render already owns state/progress
            // for this note, so there's nothing to clean up here.
        } catch {
            if renderGenerationByNoteID[noteID] == generation {
                renderStateByNoteID[noteID] = .failed(error.localizedDescription)
            }
        }
        if renderGenerationByNoteID[noteID] == generation {
            renderTasksByNoteID[noteID] = nil
        }
    }
}
