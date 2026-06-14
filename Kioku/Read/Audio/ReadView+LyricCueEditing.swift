import Foundation
import SwiftUI
import SwiftWhisperAlign

// In-place subtitle-cue editing driven from the lyric view's persistent top control row.
// Two classes of fix live here:
//   1. Timing-boundary nudges (set start/end to the playhead, ±step) — pure {startMs,endMs}
//      mutations persisted immediately and pushed to the controller via `updateCues` so the
//      karaoke highlight tracks the edit without the playback reset a full `load()` would cause.
//   2. "Fix this line's word sweep" — re-runs on-device forced alignment over a padded window
//      around the cue, tightening its boundaries AND regenerating the per-character checkpoints
//      that drive the word/character highlight sweep.
// Intent emitted by the lyric view's editing row. Carrying the cue index explicitly (rather
// than reading `controller.activeCueIndex`) lets the user edit the cue they're *looking at*
// while dragging through the scroller, which may differ from the one playing.
enum LyricCueEdit {
    case setStart(cueIndex: Int)
    case setEnd(cueIndex: Int)
    // Set the line's start/end boundary to an EXPLICIT timestamp (vs. the live playhead used by
    // setStart/setEnd). Emitted by the long-press word menu to snap the cue boundary to the tapped
    // word's time, letting the user retime a line they're looking at without scrubbing playback to it.
    case setStartToMs(cueIndex: Int, ms: Int)
    case setEndToMs(cueIndex: Int, ms: Int)
    case nudgeStart(cueIndex: Int, deltaMs: Int)
    case nudgeEnd(cueIndex: Int, deltaMs: Int)
    case realignWord(cueIndex: Int)
    // Per-word karaoke timing from the long-press menu: snap the start (or end) of the word at
    // `charOffset`/`charLength` (cue-local UTF-16) to `ms`. Edits the cue's `CueCharTiming`
    // checkpoints — creating them if the line had none, so word timing can be hand-built by ear.
    case setWordStartToPlayhead(cueIndex: Int, charOffset: Int, charLength: Int, ms: Int)
    case setWordEndToPlayhead(cueIndex: Int, charOffset: Int, charLength: Int, ms: Int)
}

extension ReadView {

    // Smallest cue span we allow an edit to produce, so a boundary can never cross or collapse
    // onto its partner.
    private var minCueDurationMs: Int { 50 }

    // Applies a timing-boundary edit immediately: clamps the new boundary, persists the cue
    // list, and refreshes the controller's in-memory copy. `realignWord` is async, so it hands
    // off to `realignActiveCueWord` instead.
    @MainActor
    func applyLyricCueEdit(_ edit: LyricCueEdit) {
        // Async / non-cue-boundary edits handled up front, then return.
        switch edit {
        case .realignWord(let idx):
            Task { await realignActiveCueWord(cueIndex: idx) }
            return
        case .setWordStartToPlayhead(let idx, let off, let len, let ms):
            setWordTiming(cueIndex: idx, charOffset: off, charLength: len, ms: ms, isEnd: false)
            return
        case .setWordEndToPlayhead(let idx, let off, let len, let ms):
            setWordTiming(cueIndex: idx, charOffset: off, charLength: len, ms: ms, isEnd: true)
            return
        default:
            break
        }

        guard let attachmentID = activeAudioAttachmentID else { return }
        let durationMs = audioController.duration > 0 ? Int(audioController.duration * 1000) : Int.max

        switch edit {
        case .setStart(let idx):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let end = audioAttachmentCues[idx].endMs
            audioAttachmentCues[idx].startMs = max(0, min(audioController.currentTimeMs, end - minCueDurationMs))
        case .setEnd(let idx):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let start = audioAttachmentCues[idx].startMs
            audioAttachmentCues[idx].endMs = min(durationMs, max(audioController.currentTimeMs, start + minCueDurationMs))
        case .setStartToMs(let idx, let ms):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let end = audioAttachmentCues[idx].endMs
            audioAttachmentCues[idx].startMs = max(0, min(ms, end - minCueDurationMs))
        case .setEndToMs(let idx, let ms):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let start = audioAttachmentCues[idx].startMs
            audioAttachmentCues[idx].endMs = min(durationMs, max(ms, start + minCueDurationMs))
        case .nudgeStart(let idx, let delta):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let end = audioAttachmentCues[idx].endMs
            audioAttachmentCues[idx].startMs = max(0, min(audioAttachmentCues[idx].startMs + delta, end - minCueDurationMs))
        case .nudgeEnd(let idx, let delta):
            guard audioAttachmentCues.indices.contains(idx) else { return }
            let start = audioAttachmentCues[idx].startMs
            audioAttachmentCues[idx].endMs = min(durationMs, max(start + minCueDurationMs, audioAttachmentCues[idx].endMs + delta))
        case .realignWord, .setWordStartToPlayhead, .setWordEndToPlayhead:
            return  // handled above
        }

        do {
            try NotesAudioStore.shared.saveCues(audioAttachmentCues, attachmentID: attachmentID)
        } catch {
            print("[ReadView] saveCues after in-place lyric edit failed: \(error.localizedDescription)")
        }
        audioController.updateCues(audioAttachmentCues)
    }

    // Snaps one word's karaoke checkpoint to `ms`. `isEnd == false` sets the word's START — the
    // checkpoint at the word's own char offset. `isEnd == true` sets the word's END, which is the
    // start of the NEXT word (the checkpoint at charOffset+charLength); for the last word that's
    // the line end, so we move the cue's `endMs` instead. Checkpoints are created when missing,
    // so a line with no timing can be hand-built word by word.
    @MainActor
    private func setWordTiming(cueIndex: Int, charOffset: Int, charLength: Int, ms: Int, isEnd: Bool) {
        guard let attachmentID = activeAudioAttachmentID,
              audioAttachmentCues.indices.contains(cueIndex) else { return }
        let cue = audioAttachmentCues[cueIndex]
        let textLength = cue.text.utf16.count
        let targetOffset = isEnd ? (charOffset + charLength) : charOffset
        let clampedMs = max(0, ms)

        // The last word's "end" is the line end — there's no next-word checkpoint to anchor.
        if isEnd && targetOffset >= textLength {
            let durationMs = audioController.duration > 0 ? Int(audioController.duration * 1000) : Int.max
            audioAttachmentCues[cueIndex].endMs = min(durationMs, max(cue.startMs + minCueDurationMs, clampedMs))
            do {
                try NotesAudioStore.shared.saveCues(audioAttachmentCues, attachmentID: attachmentID)
            } catch {
                print("[ReadView] saveCues after word-end edit failed: \(error.localizedDescription)")
            }
            audioController.updateCues(audioAttachmentCues)
            return
        }

        var checkpoints = cue.checkpoints
        if let existing = checkpoints.firstIndex(where: { $0.charOffsetInCue == targetOffset }) {
            checkpoints[existing].timeMs = clampedMs
        } else {
            let length = isEnd ? max(1, textLength - targetOffset) : max(1, charLength)
            checkpoints.append(CueCharTiming(timeMs: clampedMs, charOffsetInCue: targetOffset, charLength: length))
        }
        // Keep checkpoints ordered by position so the sweep advances left-to-right.
        checkpoints.sort { $0.charOffsetInCue < $1.charOffsetInCue }
        audioAttachmentCues[cueIndex].checkpoints = checkpoints

        do {
            try NotesAudioStore.shared.saveCues(audioAttachmentCues, attachmentID: attachmentID)
        } catch {
            print("[ReadView] saveCues after word-timing edit failed: \(error.localizedDescription)")
        }
        // The updated cues feed the highlight observer reactively. updateCues keeps the controller's
        // copy in sync; its boundaries are unchanged but its checkpoints now match.
        audioController.updateCues(audioAttachmentCues)
    }

    // Re-runs on-device forced alignment for a single cue over a padded window around its
    // current bounds, then tightens the cue's start/end from the new line span and rebuilds its
    // per-character karaoke checkpoints. Persists cues + timings and refreshes the controller.
    @MainActor
    func realignActiveCueWord(cueIndex: Int) async {
        // One re-align at a time — the spinner and the gate share `realigningCueIndex`.
        guard realigningCueIndex == nil else { return }
        guard let attachmentID = activeAudioAttachmentID,
              audioAttachmentCues.indices.contains(cueIndex),
              let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
        guard let modelURL = OnDeviceLyricAligner.bestAvailableModelURL() else {
            cueRealignErrorMessage = "Download a Whisper model in Settings → Whisper Models to re-align lyrics on device."
            return
        }

        let cue = audioAttachmentCues[cueIndex]
        let lineText = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to align for instrumental ♪ markers or blank cues.
        guard lineText.isEmpty == false, SubtitleParser.isNonSpeechCue(lineText) == false else { return }

        let durationMs = audioController.duration > 0 ? Int(audioController.duration * 1000) : cue.endMs + 2000
        // Pad the window so a badly-mistimed cue still contains its real audio. The forced
        // decoder places this one line within the window; the boundaries come back tightened.
        let padMs = 1500
        let windowStart = Double(max(0, cue.startMs - padMs)) / 1000.0
        let windowEnd = Double(min(durationMs, cue.endMs + padMs)) / 1000.0

        realigningCueIndex = cueIndex
        defer { realigningCueIndex = nil }

        do {
            let result = try await OnDeviceLyricAligner.realignLine(
                audioURL: audioURL,
                line: lineText,
                windowStartSeconds: windowStart,
                windowEndSeconds: windowEnd,
                modelURL: modelURL
            )

            // The cue list can shift while alignment runs (note switch, another edit). Re-find
            // the same cue by its stable SRT index and bail if it's gone or moved.
            guard audioAttachmentCues.indices.contains(cueIndex),
                  audioAttachmentCues[cueIndex].index == cue.index else { return }

            // Tighten boundaries from the new line span.
            let newStart = max(0, Int((result.line.start * 1000).rounded()))
            let newEnd = min(durationMs, max(newStart + minCueDurationMs, Int((result.line.end * 1000).rounded())))
            audioAttachmentCues[cueIndex].startMs = newStart
            audioAttachmentCues[cueIndex].endMs = newEnd

            // Rebuild this cue's per-character checkpoints inline (empty when the sweep found none).
            let checkpoints = result.tokens
                .map { token in
                    CueCharTiming(
                        timeMs: max(0, Int((token.start * 1000).rounded())),
                        charOffsetInCue: token.charOffsetUTF16,
                        charLength: token.charLengthUTF16
                    )
                }
                .sorted { $0.timeMs < $1.timeMs }
            audioAttachmentCues[cueIndex].checkpoints = checkpoints

            do {
                try NotesAudioStore.shared.saveCues(audioAttachmentCues, attachmentID: attachmentID)
            } catch {
                print("[ReadView] persist after cue re-align failed: \(error.localizedDescription)")
            }
            audioController.updateCues(audioAttachmentCues)
        } catch is CancellationError {
            // User navigated away mid-align; nothing to surface.
        } catch {
            cueRealignErrorMessage = "Couldn't re-align this line: \(error.localizedDescription)"
        }
    }

    // Drives the dedicated re-align failure alert from the message string.
    var cueRealignErrorPresented: Binding<Bool> {
        Binding(
            get: { cueRealignErrorMessage.isEmpty == false },
            set: { presented in
                if presented == false { cueRealignErrorMessage = "" }
            }
        )
    }
}
