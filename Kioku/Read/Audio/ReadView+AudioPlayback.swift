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
        audioPlayback.audioSource = .mix
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

    // Moves the lyrics view's playback to the next source (Mix → Vocals → Instrumental), keeping
    // the playhead and play state. The instrumental is built from the cached stem on first use, so
    // the switch waits for it off the main thread; if a source isn't available (no stem cached) the
    // cycle skips past it.
    func cycleLyricAudioSource() {
        guard audioPlayback.isSwitchingAudioSource == false,
              let id = audioPlayback.activeAudioAttachmentID,
              let originalURL = NotesAudioStore.shared.audioURL(for: id) else { return }
        audioPlayback.isSwitchingAudioSource = true
        let target = audioPlayback.audioSource.next
        Task {
            let resolved: (LyricsAudioSource, URL) = await {
                var candidate = target
                for _ in 0..<3 {
                    let url: URL?
                    switch candidate {
                    case .mix: url = originalURL
                    case .vocals: url = VocalStemCache.playableStemURL(for: originalURL)
                    case .instrumental:
                        url = await Task.detached(priority: .userInitiated) {
                            await VocalStemCache.playableInstrumentalURL(for: originalURL)
                        }.value
                    }
                    if let url { return (candidate, url) }
                    candidate = candidate.next
                }
                return (.mix, originalURL)
            }()
            await MainActor.run {
                defer { audioPlayback.isSwitchingAudioSource = false }
                // The user may have closed this song while the instrumental was building.
                guard audioPlayback.activeAudioAttachmentID == id else { return }
                do {
                    try audioPlayback.audioController.switchSource(to: resolved.1)
                    audioPlayback.audioSource = resolved.0
                } catch {
                    print("[ReadView] audio source switch to \(resolved.0.label) failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
