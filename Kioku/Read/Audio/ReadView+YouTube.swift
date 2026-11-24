import SwiftUI

// Hosts the YouTube link flow for ReadView: a pasted link either gives a note without audio its
// audio (fetched, then aligned like a picked file) or, on a note that already has audio, just adds
// the video beside the lyrics.
extension ReadView {
    // Handles a pasted YouTube link for the active note.
    // With no audio attached, downloads the video's audio and runs it through the normal import and
    // alignment path; with audio, only records the video so it plays along. Failures land in the
    // shared alignment-failure alert, and a failed first import leaves the note without the video.
    @MainActor
    func addYouTubeVideo(from link: String, useCaptions: Bool? = nil, replaceAudio: Bool? = nil) async {
        guard lyricAlignment.isAligning == false else { return }
        guard let videoID = YouTubeVideoID.parse(link) else {
            lyricAlignment.errorMessage = "That doesn't look like a YouTube link."
            return
        }
        flushPendingNotePersistenceIfNeeded()
        // An empty note is offered the video's own captions as its text before anything else runs.
        // `useCaptions` is nil on the first pass and carries the user's answer on the resumed one.
        if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if useCaptions == nil {
                lyricAlignment.isAligning = true
                lyricAlignment.progressMessage = "Looking for captions…"
                let captions = await YouTubeCaptionFetcher.japaneseCaptions(videoID: videoID)
                finishYouTubeFetch()
                if let captions {
                    subtitleImport.youTubeCaptionOffer = captions
                    subtitleImport.youTubeCaptionLink = link
                    subtitleImport.isShowingYouTubeCaptionOffer = true
                    return
                }
            } else if useCaptions == true, let captions = subtitleImport.youTubeCaptionOffer {
                document.text = captions.text
                flushPendingNotePersistenceIfNeeded()
            }
        }
        subtitleImport.youTubeCaptionOffer = nil

        // A brand-new note that was never typed into has no stored identity yet; give it one now
        // that something is about to be attached to it.
        let noteID: UUID
        if let activeID = document.activeNoteID {
            noteID = activeID
        } else {
            let fresh = Note()
            notesStore.addNote(fresh)
            document.activeNoteID = fresh.id
            onActiveNoteChanged?(fresh.id)
            noteID = fresh.id
        }

        // A note that already has audio is asked whether the video's own audio should replace it
        // (re-aligning the lyrics, so the video stays in step) or the video should just play along.
        if audioPlayback.activeAudioAttachmentID != nil {
            switch replaceAudio {
            case nil:
                subtitleImport.youTubeReplaceLink = link
                subtitleImport.isShowingYouTubeReplaceChoice = true
                return
            case false?:
                setYouTubeVideo(videoID, noteID: noteID)
                return
            case true?:
                break
            }
        }

        lyricAlignment.isAligning = true
        subtitleImport.isCancellingAlignment = false
        subtitleImport.alignmentCancellationToken.reset()
        lyricAlignment.progressMessage = "Fetching audio from YouTube…"
        let token = subtitleImport.alignmentCancellationToken
        let download: YouTubeAudioDownload
        do {
            download = try await YouTubeAudioDownloader.download(
                videoID: videoID,
                isCancelled: { token.isCancelled },
                onProgress: { fraction in
                    Task { @MainActor in lyricAlignment.progressMessage = "Downloading audio… \(Int(fraction * 100))%" }
                }
            )
        } catch is CancellationError {
            finishYouTubeFetch()
            return
        } catch {
            AppLog.error(.audioAlignment, "youtube \(videoID) audio fetch failed — \(error.localizedDescription)")
            lyricAlignment.errorMessage = error.localizedDescription
            finishYouTubeFetch()
            return
        }
        finishYouTubeFetch()

        // Stage the download exactly as a picked audio file would be, then let the shared import run.
        clearPendingSubtitleAudioSelection()
        clearPendingSubtitleFileSelection()
        clearPendingSubtitleTextGridSelection()
        subtitleImport.pendingSubtitleAudioURL = download.fileURL
        subtitleImport.pendingSubtitleAudioFilename = (download.title.isEmpty ? videoID : download.title) + ".m4a"
        setYouTubeVideo(videoID, noteID: noteID)
        await submitPendingSubtitleSelection()

        // A failed import leaves its temporary copy behind and no audio; drop both so the note is as before.
        clearPendingSubtitleAudioSelection()
        if audioPlayback.activeAudioAttachmentID == nil {
            setYouTubeVideo(nil, noteID: noteID)
        }
    }

    // Ends the fetch phase's progress state; the alignment that follows sets its own.
    @MainActor
    private func finishYouTubeFetch() {
        lyricAlignment.isAligning = false
        lyricAlignment.progressMessage = ""
        subtitleImport.isCancellingAlignment = false
    }

    // Detaches the note's video, leaving its audio and lyrics as they are, and leaves video mode.
    @MainActor
    func removeYouTubeVideo() {
        guard let noteID = document.activeNoteID else { return }
        audioPlayback.isVideoMode = false
        setYouTubeVideo(nil, noteID: noteID)
    }

    // Records (or clears) the note's video in the store and in the open lyrics view.
    @MainActor
    private func setYouTubeVideo(_ videoID: String?, noteID: UUID) {
        notesStore.updateYouTubeVideoID(id: noteID, videoID: videoID)
        audioPlayback.youTubeVideoID = videoID
    }
}
