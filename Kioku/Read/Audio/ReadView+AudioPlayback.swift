import Foundation

// Hosts audio attachment loading logic for ReadView so audio infrastructure stays isolated
// from the main view body.
extension ReadView {
    // Loads the audio file and cues for a given attachment ID, or unloads when nil.
    func loadAudioAttachmentIfNeeded(attachmentID: UUID?) {
        guard let attachmentID else {
            audioController.unload()
            audioAttachmentCues = []
            selectedHighlightRangeOverride = nil
            return
        }

        let cues = NoteAudioStore.shared.loadCues(for: attachmentID)
        audioAttachmentCues = cues

        guard let audioURL = NoteAudioStore.shared.audioURL(for: attachmentID) else {
            // Cues were found but audio file is missing — show subtitle highlights only.
            return
        }

        do {
            try audioController.load(audioURL: audioURL, cues: cues)
        } catch {
            // Audio file exists but couldn't be opened; degrade gracefully without blocking editing.
            audioAttachmentCues = []
        }
    }
}
