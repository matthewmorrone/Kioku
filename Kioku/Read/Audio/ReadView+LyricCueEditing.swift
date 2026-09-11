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
    // Like setStart, but ALSO shifts every following line up to the next ♪ marker by the same delta.
    // Fixes a whole section that drifted uniformly (the common residual: a span of lines all a few
    // seconds late because their anchorless window was bounded slightly off) with a single tap.
    case setStartRipple(cueIndex: Int)
    // Set the line's start/end boundary to an EXPLICIT timestamp (vs. the live playhead used by
    // setStart/setEnd). Emitted by the long-press word menu to snap the cue boundary to the tapped
    // word's time, letting the user retime a line they're looking at without scrubbing playback to it.
    case setStartToMs(cueIndex: Int, ms: Int)
    case setEndToMs(cueIndex: Int, ms: Int)
    case realignWord(cueIndex: Int)
    // Re-run the FULL alignment pipeline (CTC + vocal separation) over the whole note's lyrics
    // against the attached audio, replacing the entire cue list — the lyric view's top "Re-align"
    // action. Unlike `realignWord` (one line, windowed) this is a from-scratch realign of everything.
    case realignAll
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
        case .realignAll:
            Task { await realignWholeNote() }
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

        guard let attachmentID = audioPlayback.activeAudioAttachmentID else { return }
        let durationMs = audioPlayback.audioController.duration > 0 ? Int(audioPlayback.audioController.duration * 1000) : Int.max

        switch edit {
        case .setStart(let idx):
            guard audioPlayback.audioAttachmentCues.indices.contains(idx) else { return }
            // "Start here": relocate the WHOLE line so it begins at the playhead, preserving its
            // duration — start, end, and every word-checkpoint shift by the same delta. The old
            // behavior clamped the new start to the line's own end, which made it impossible to move
            // a line LATER than where it currently ends (the common fix for a line timed too early —
            // it silently did almost nothing). Floor at the previous line's start so a move can't
            // reorder cues; cap at the song length, not the line's own end.
            let floor = idx > 0 ? audioPlayback.audioAttachmentCues[idx - 1].startMs : 0
            let desired = max(floor, min(audioPlayback.audioController.currentTimeMs, durationMs - minCueDurationMs))
            let delta = desired - audioPlayback.audioAttachmentCues[idx].startMs
            guard delta != 0 else { return }
            let newStart = max(0, audioPlayback.audioAttachmentCues[idx].startMs + delta)
            audioPlayback.audioAttachmentCues[idx].startMs = newStart
            audioPlayback.audioAttachmentCues[idx].endMs = min(durationMs, max(newStart + minCueDurationMs, audioPlayback.audioAttachmentCues[idx].endMs + delta))
            for k in audioPlayback.audioAttachmentCues[idx].checkpoints.indices {
                audioPlayback.audioAttachmentCues[idx].checkpoints[k].timeMs = max(0, audioPlayback.audioAttachmentCues[idx].checkpoints[k].timeMs + delta)
            }
        case .setStartRipple(let idx):
            guard audioPlayback.audioAttachmentCues.indices.contains(idx) else { return }
            // Clamp the target's new start between the previous line's start and the song length, then
            // shift it and every following line (until the next ♪) — boundaries AND checkpoints — by
            // that same delta, so a uniformly-drifted section snaps into place in one tap. Capping at
            // the song length (not the line's own end) lets a section be dragged forward past where it
            // currently sits — without that, the ripple silently did almost nothing for late sections.
            let floorMs = idx > 0 ? audioPlayback.audioAttachmentCues[idx - 1].startMs : 0
            let desired = max(floorMs, min(audioPlayback.audioController.currentTimeMs, durationMs - minCueDurationMs))
            let delta = desired - audioPlayback.audioAttachmentCues[idx].startMs
            guard delta != 0 else { return }
            var i = idx
            while i < audioPlayback.audioAttachmentCues.count {
                if i > idx, SubtitleParser.isNonSpeechCue(audioPlayback.audioAttachmentCues[i].text) { break }
                let ns = max(0, audioPlayback.audioAttachmentCues[i].startMs + delta)
                audioPlayback.audioAttachmentCues[i].startMs = ns
                audioPlayback.audioAttachmentCues[i].endMs = min(durationMs, max(ns + minCueDurationMs, audioPlayback.audioAttachmentCues[i].endMs + delta))
                for k in audioPlayback.audioAttachmentCues[i].checkpoints.indices {
                    audioPlayback.audioAttachmentCues[i].checkpoints[k].timeMs = max(0, audioPlayback.audioAttachmentCues[i].checkpoints[k].timeMs + delta)
                }
                i += 1
            }
        case .setEnd(let idx):
            guard audioPlayback.audioAttachmentCues.indices.contains(idx) else { return }
            let start = audioPlayback.audioAttachmentCues[idx].startMs
            audioPlayback.audioAttachmentCues[idx].endMs = min(durationMs, max(audioPlayback.audioController.currentTimeMs, start + minCueDurationMs))
        case .setStartToMs(let idx, let ms):
            guard audioPlayback.audioAttachmentCues.indices.contains(idx) else { return }
            let end = audioPlayback.audioAttachmentCues[idx].endMs
            audioPlayback.audioAttachmentCues[idx].startMs = max(0, min(ms, end - minCueDurationMs))
        case .setEndToMs(let idx, let ms):
            guard audioPlayback.audioAttachmentCues.indices.contains(idx) else { return }
            let start = audioPlayback.audioAttachmentCues[idx].startMs
            audioPlayback.audioAttachmentCues[idx].endMs = min(durationMs, max(ms, start + minCueDurationMs))
        case .realignWord, .realignAll, .setWordStartToPlayhead, .setWordEndToPlayhead:
            return  // handled above
        }

        do {
            try NotesAudioStore.shared.saveCues(audioPlayback.audioAttachmentCues, attachmentID: attachmentID)
        } catch {
            print("[ReadView] saveCues after in-place lyric edit failed: \(error.localizedDescription)")
        }
        audioPlayback.audioController.updateCues(audioPlayback.audioAttachmentCues)
    }

    // Snaps one word's karaoke checkpoint to `ms`. `isEnd == false` sets the word's START — the
    // checkpoint at the word's own char offset. `isEnd == true` sets the word's END, which is the
    // start of the NEXT word (the checkpoint at charOffset+charLength); for the last word that's
    // the line end, so we move the cue's `endMs` instead. Checkpoints are created when missing,
    // so a line with no timing can be hand-built word by word.
    @MainActor
    private func setWordTiming(cueIndex: Int, charOffset: Int, charLength: Int, ms: Int, isEnd: Bool) {
        guard let attachmentID = audioPlayback.activeAudioAttachmentID,
              audioPlayback.audioAttachmentCues.indices.contains(cueIndex) else { return }
        let cue = audioPlayback.audioAttachmentCues[cueIndex]
        let textLength = cue.text.utf16.count
        let targetOffset = isEnd ? (charOffset + charLength) : charOffset
        let clampedMs = max(0, ms)

        // The last word's "end" is the line end — there's no next-word checkpoint to anchor.
        if isEnd && targetOffset >= textLength {
            let durationMs = audioPlayback.audioController.duration > 0 ? Int(audioPlayback.audioController.duration * 1000) : Int.max
            audioPlayback.audioAttachmentCues[cueIndex].endMs = min(durationMs, max(cue.startMs + minCueDurationMs, clampedMs))
            do {
                try NotesAudioStore.shared.saveCues(audioPlayback.audioAttachmentCues, attachmentID: attachmentID)
            } catch {
                print("[ReadView] saveCues after word-end edit failed: \(error.localizedDescription)")
            }
            audioPlayback.audioController.updateCues(audioPlayback.audioAttachmentCues)
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
        audioPlayback.audioAttachmentCues[cueIndex].checkpoints = checkpoints

        do {
            try NotesAudioStore.shared.saveCues(audioPlayback.audioAttachmentCues, attachmentID: attachmentID)
        } catch {
            print("[ReadView] saveCues after word-timing edit failed: \(error.localizedDescription)")
        }
        // The updated cues feed the highlight observer reactively. updateCues keeps the controller's
        // copy in sync; its boundaries are unchanged but its checkpoints now match.
        audioPlayback.audioController.updateCues(audioPlayback.audioAttachmentCues)
    }

    // Re-runs on-device forced alignment for a single cue over a padded window around its
    // current bounds, then tightens the cue's start/end from the new line span and rebuilds its
    // per-character karaoke checkpoints. Persists cues + timings and refreshes the controller.
    @MainActor
    func realignActiveCueWord(cueIndex: Int) async {
        // One re-align at a time — the spinner and the gate share `lyricRealign.realigningCueIndex`.
        guard lyricRealign.realigningCueIndex == nil else { return }
        guard let attachmentID = audioPlayback.activeAudioAttachmentID,
              audioPlayback.audioAttachmentCues.indices.contains(cueIndex),
              let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
        guard let modelURL = OnDeviceLyricAligner.bestAvailableModelURL() else {
            lyricRealign.cueRealignErrorMessage = "Download a Whisper model in Settings → Whisper Models to re-align lyrics on device."
            return
        }

        let cue = audioPlayback.audioAttachmentCues[cueIndex]
        let lineText = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to align for instrumental ♪ markers or blank cues.
        guard lineText.isEmpty == false, SubtitleParser.isNonSpeechCue(lineText) == false else { return }

        let durationMs = audioPlayback.audioController.duration > 0 ? Int(audioPlayback.audioController.duration * 1000) : cue.endMs + 2000
        // Pad the window so a badly-mistimed cue still contains its real audio. The forced
        // decoder places this one line within the window; the boundaries come back tightened.
        let padMs = 1500
        let windowStart = Double(max(0, cue.startMs - padMs)) / 1000.0
        let windowEnd = Double(min(durationMs, cue.endMs + padMs)) / 1000.0

        lyricRealign.realigningCueIndex = cueIndex
        defer { lyricRealign.realigningCueIndex = nil }

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
            guard audioPlayback.audioAttachmentCues.indices.contains(cueIndex),
                  audioPlayback.audioAttachmentCues[cueIndex].index == cue.index else { return }

            // Tighten boundaries from the new line span.
            let newStart = max(0, Int((result.line.start * 1000).rounded()))
            let newEnd = min(durationMs, max(newStart + minCueDurationMs, Int((result.line.end * 1000).rounded())))
            audioPlayback.audioAttachmentCues[cueIndex].startMs = newStart
            audioPlayback.audioAttachmentCues[cueIndex].endMs = newEnd

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
            audioPlayback.audioAttachmentCues[cueIndex].checkpoints = checkpoints

            do {
                try NotesAudioStore.shared.saveCues(audioPlayback.audioAttachmentCues, attachmentID: attachmentID)
            } catch {
                print("[ReadView] persist after cue re-align failed: \(error.localizedDescription)")
            }
            audioPlayback.audioController.updateCues(audioPlayback.audioAttachmentCues)
        } catch is CancellationError {
            // User navigated away mid-align; nothing to surface.
        } catch {
            lyricRealign.cueRealignErrorMessage = "Couldn't re-align this line: \(error.localizedDescription)"
        }
    }

    // Drives the dedicated re-align failure alert from the message string.
    var cueRealignErrorPresented: Binding<Bool> {
        Binding(
            get: { lyricRealign.cueRealignErrorMessage.isEmpty == false },
            set: { presented in
                if presented == false { lyricRealign.cueRealignErrorMessage = "" }
            }
        )
    }
}
