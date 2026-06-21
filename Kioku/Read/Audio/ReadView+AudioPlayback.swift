import Foundation
import SwiftWhisperAlign

// Hosts audio attachment loading logic for ReadView so audio infrastructure stays isolated
// from the main view body.
extension ReadView {
    // Loads the audio file and cues for a given attachment ID, or unloads when nil.
    // Highlight ranges are resolved from the current note text at load time so stale
    // import-time offsets can never silently break playback highlighting.
    func loadAudioAttachmentIfNeeded(attachmentID: UUID?) {
        // A new (or cleared) attachment means a different audio source — start on the original
        // mix so the Vocals/Mix toggle never carries a stale "Vocals" state onto another song.
        isListeningToStem = false
        guard let attachmentID else {
            StartupTimer.mark("loadAudioAttachmentIfNeeded clearing attachment")
            audioController.unload()
            audioAttachmentCues = []
            audioAttachmentHighlightRanges = []
            activeAudioAttachmentID = nil
            isShowingLyricsView = false
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
            selectedHighlightRangeOverride = nil
            return
        }

        StartupTimer.mark("loadAudioAttachmentIfNeeded start")
        isShowingLyricsView = false
        activeAudioAttachmentID = attachmentID
        let cues = StartupTimer.measure("loadAudioAttachmentIfNeeded.loadCues") {
            NotesAudioStore.shared.loadCues(for: attachmentID)
        }
        audioAttachmentCues = cues
        audioAttachmentHighlightRanges = StartupTimer.measure("loadAudioAttachmentIfNeeded.resolveHighlightRanges") {
            SubtitleParser.resolveHighlightRanges(for: cues, in: text)
        }
        // Checkpoints arrive inline on each cue from loadCues — no separate timings load.
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

    // Whether an isolated vocal stem is cached for the active audio — gates the lyric bar's
    // Vocals/Mix toggle (only meaningful after a Re-align has produced and cached a stem).
    var stemAvailableForActiveAudio: Bool {
        guard let id = activeAudioAttachmentID,
              let url = NotesAudioStore.shared.audioURL(for: id) else { return false }
        return VocalStemCache.hasStem(for: url)
    }

    // Swaps lyric playback between the original mix and the isolated vocal stem, preserving the
    // playhead and play/pause state. The stem's playable WAV is generated from the cached f32 on
    // first use (a brief transcode). If no stem is actually available — e.g. the OS reclaimed the
    // cache — it reverts the toggle rather than leave it half-switched.
    func switchLyricAudioSource(toStem: Bool) {
        guard let id = activeAudioAttachmentID,
              let originalURL = NotesAudioStore.shared.audioURL(for: id) else { return }
        let target = toStem ? VocalStemCache.stemWAVURL(for: originalURL) : originalURL
        guard let target else { isListeningToStem = false; return }
        try? audioController.switchSource(to: target)
    }
}
