import Foundation
import Observation

// Owns ReadView's subtitle/audio import state: transcription progress, the staged
// audio/SRT/TextGrid picks awaiting confirmation, and the import-flow sheets/pickers. An
// alignment run's own progress/error lives in LyricAlignmentUIState, which the lyric view
// renders; only the cancellation token stays here, shared by both entry points.
// Extracted from ReadView's own @State — see LLMCorrectionUIState for the same rationale
// applied to the LLM-correction feature.
@Observable
final class SubtitleImportUIState {
    var isShowingFileImporter = false
    var isShowingSubtitlePopup = false
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
    var isShowingSubtitlePicker = false
    var subtitlePickerTarget: SubtitlePickerTarget = .audio
    // Drives the lyric-button "nothing loaded yet" media picker (mp3 + srt + textgrid, multi-select).
    var isShowingLyricMediaPicker = false
}
