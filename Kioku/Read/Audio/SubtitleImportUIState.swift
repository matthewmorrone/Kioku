import Foundation
import Observation

// Owns ReadView's subtitle/audio import state: transcription progress, the staged
// audio/SRT/TextGrid picks from the lyric-button media picker. An
// alignment run's own progress/error lives in LyricAlignmentUIState, which the lyric view
// renders; only the cancellation token stays here, shared by both entry points.
// Extracted from ReadView's own @State so it reads as one unit.
@Observable
final class SubtitleImportUIState {
    var isPerformingAudioTranscription = false
    var isCancellingAlignment = false
    var alignmentCancellationToken = AlignmentCancellationToken()
    var audioTranscriptionErrorMessage = ""
    // An imported audio file that sounded sung, held (as its temporary copy) while the
    // "find the lyrics online" recommendation is showing; transcribed only on Transcribe Anyway.
    var pendingSungAudioURL: URL? = nil
    var isShowingSungAudioRecommendation = false
    var pendingSubtitleAudioURL: URL? = nil
    var pendingSubtitleAudioFilename = ""
    var pendingSubtitleFileURL: URL? = nil
    var pendingSubtitleFilename = ""
    var pendingSubtitleTextGridURL: URL? = nil
    var pendingSubtitleTextGridFilename = ""
    // Drives the lyric-button "nothing loaded yet" media picker (mp3 + srt + textgrid, multi-select).
    var isShowingLyricMediaPicker = false
    // The "audio file or YouTube link?" choice shown from the lyric button when nothing is attached,
    // and the link prompt it opens.
    var isShowingLyricSourceChoice = false
    var isShowingYouTubePrompt = false
    var isShowingYouTubeSearch = false
    var isShowingYouTubeReplaceChoice = false
    var youTubeReplaceLink = ""
    var youTubeLinkText = ""
    // Captions found for a link pasted into an empty note, held while the "use these as the note's
    // text?" offer is showing, along with the link to resume with.
    var youTubeCaptionOffer: YouTubeCaptions?
    var youTubeCaptionLink = ""
    var isShowingYouTubeCaptionOffer = false
}
