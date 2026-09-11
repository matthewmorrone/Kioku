import Foundation
import Observation

// Owns ReadView's subtitle/audio import state: transcription and forced-alignment progress,
// the staged audio/SRT/TextGrid picks awaiting confirmation, and the import-flow sheets/pickers.
// Extracted from ReadView's own @State — see LLMCorrectionUIState for the same rationale
// applied to the LLM-correction feature.
@Observable
final class SubtitleImportUIState {
    var isShowingFileImporter = false
    var isShowingSubtitlePopup = false
    var isPerformingAudioTranscription = false
    var isGeneratingLyricAlignment = false
    var isCancellingAlignment = false
    var alignmentCancellationToken = AlignmentCancellationToken()
    var audioTranscriptionErrorMessage = ""
    var lyricAlignmentErrorMessage = ""
    var lyricAlignmentProgressMessage = ""
    var lyricAlignmentSourceFilename = ""
    var alignmentResultSRT = ""
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
