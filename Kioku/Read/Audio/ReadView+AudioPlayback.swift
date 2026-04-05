import Foundation

// Hosts audio attachment loading logic for ReadView so audio infrastructure stays isolated
// from the main view body.
extension ReadView {
    // Loads the audio file and cues for a given attachment ID, or unloads when nil.
    // Highlight ranges are resolved from the current note text at load time so stale
    // import-time offsets can never silently break playback highlighting.
    func loadAudioAttachmentIfNeeded(attachmentID: UUID?) {
        guard let attachmentID else {
            StartupTimer.mark("loadAudioAttachmentIfNeeded clearing attachment")
            audioController.unload()
            audioAttachmentCues = []
            audioAttachmentHighlightRanges = []
            activeAudioAttachmentID = nil
            isShowingLyricsView = false
            lyricsTranslationCache.clear()
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
            selectedHighlightRangeOverride = nil
            return
        }

        StartupTimer.mark("loadAudioAttachmentIfNeeded start")
        isShowingLyricsView = false
        lyricsTranslationCache.clear()
        activeAudioAttachmentID = attachmentID
        let cues = StartupTimer.measure("loadAudioAttachmentIfNeeded.loadCues") {
            NotesAudioStore.shared.loadCues(for: attachmentID)
        }
        audioAttachmentCues = cues
        audioAttachmentHighlightRanges = StartupTimer.measure("loadAudioAttachmentIfNeeded.resolveHighlightRanges") {
            SubtitleParser.resolveHighlightRanges(for: cues, in: text)
        }
        playbackHighlightRangeOverride = nil
        activePlaybackCueIndex = nil

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
                try audioController.load(audioURL: audioURL, cues: cues)
            }
            StartupTimer.mark("loadAudioAttachmentIfNeeded finished")
        } catch {
            // Audio file exists but couldn't be opened; degrade gracefully without blocking editing.
            StartupTimer.mark("loadAudioAttachmentIfNeeded failed: \(error.localizedDescription)")
            audioAttachmentCues = []
            audioAttachmentHighlightRanges = []
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
        }
    }
}
