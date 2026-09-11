import Foundation
import SwiftWhisperAlign

// Hosts audio attachment loading logic for ReadView so audio infrastructure stays isolated
// from the main view body.
extension ReadView {
    // Loads the audio file and cues for a given attachment ID, or unloads when nil.
    // Highlight ranges are resolved from the current note text at load time so stale
    // import-time offsets can never silently break playback highlighting.
    func loadAudioAttachmentIfNeeded(attachmentID: UUID?) {
        guard let attachmentID else {
            StartupTimer.mark("loadAudioAttachmentIfNeeded clearing attachment")
            audioPlayback.audioController.unload()
            audioPlayback.audioAttachmentCues = []
            audioPlayback.audioAttachmentHighlightRanges = []
            audioPlayback.activeAudioAttachmentID = nil
            audioPlayback.isShowingLyricsView = false
            audioPlayback.playbackHighlightRangeOverride = nil
            audioPlayback.activePlaybackCueIndex = nil
            segmentSelection.selectedHighlightRangeOverride = nil
            return
        }

        StartupTimer.mark("loadAudioAttachmentIfNeeded start")
        audioPlayback.isShowingLyricsView = false
        audioPlayback.activeAudioAttachmentID = attachmentID
        let cues = StartupTimer.measure("loadAudioAttachmentIfNeeded.loadCues") {
            NotesAudioStore.shared.loadCues(for: attachmentID)
        }
        audioPlayback.audioAttachmentCues = cues
        audioPlayback.audioAttachmentHighlightRanges = StartupTimer.measure("loadAudioAttachmentIfNeeded.resolveHighlightRanges") {
            SubtitleParser.resolveHighlightRanges(for: cues, in: document.text)
        }
        // Checkpoints arrive inline on each cue from loadCues — no separate timings load.
        audioPlayback.playbackHighlightRangeOverride = nil
        audioPlayback.activePlaybackCueIndex = nil

        let audioURL = StartupTimer.measure("loadAudioAttachmentIfNeeded.audioURL") {
            NotesAudioStore.shared.audioURL(for: attachmentID)
        }
        guard let audioURL else {
            // Cues were found but audio file is missing — show subtitle highlights only.
            StartupTimer.mark("loadAudioAttachmentIfNeeded audio missing")
            return
        }

        do {
            try StartupTimer.measure("loadAudioAttachmentIfNeeded.audioController.load") {
                try audioPlayback.audioController.load(audioURL: audioURL, cues: cues, title: resolvedTitle)
            }
            StartupTimer.mark("loadAudioAttachmentIfNeeded finished")
        } catch {
            // Audio file exists but couldn't be opened; degrade gracefully without blocking editing.
            StartupTimer.mark("loadAudioAttachmentIfNeeded failed: \(error.localizedDescription)")
            audioPlayback.audioAttachmentCues = []
            audioPlayback.audioAttachmentHighlightRanges = []
            audioPlayback.playbackHighlightRangeOverride = nil
            audioPlayback.activePlaybackCueIndex = nil
        }
    }
}
