import Foundation

// Hosts audio attachment loading logic for ReadView so audio infrastructure stays isolated
// from the main view body.
extension ReadView {
    // Loads the audio file and cues for a given attachment ID, or unloads when nil.
    // Highlight ranges are resolved from the current note text at load time so stale
    // import-time offsets can never silently break playback highlighting.
    func loadAudioAttachmentIfNeeded(attachmentID: UUID?) {
        guard let attachmentID else {
            audioController.unload()
            audioAttachmentCues = []
            audioAttachmentHighlightRanges = []
            activeAudioAttachmentID = nil
            selectedHighlightRangeOverride = nil
            return
        }

        activeAudioAttachmentID = attachmentID
        let cues = NoteAudioStore.shared.loadCues(for: attachmentID)
        audioAttachmentCues = cues
        audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: cues, in: text)

        guard let audioURL = NoteAudioStore.shared.audioURL(for: attachmentID) else {
            // Cues were found but audio file is missing — show subtitle highlights only.
            return
        }

        do {
            try audioController.load(audioURL: audioURL, cues: cues)
        } catch {
            // Audio file exists but couldn't be opened; degrade gracefully without blocking editing.
            audioAttachmentCues = []
            audioAttachmentHighlightRanges = []
        }
    }
}
