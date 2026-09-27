import Foundation

// Engine used to turn an imported audio file into a note (audio → text). Not user-selectable:
// Apple's SpeechTranscriber on iOS 26+ (4.9% character error on FLEURS Japanese speech vs
// Qwen3-ASR's 11.6%, PR #101), Qwen3-ASR below that. Don't bring back the older SFSpeechRecognizer
// (90.7% character error on songs) or Whisper (crashed on-device) — commit 5e729ff.
//
// This selects only the transcription engine; forced alignment stays on its own MMS model
// regardless (a separate pipeline, not user-selectable).
enum TranscriptionEngine: String, CaseIterable {
    case qwen3
    case appleTranscriber

    var displayName: String {
        switch self {
        case .qwen3:       return "Qwen3-ASR (on-device)"
        case .appleTranscriber: return "Apple SpeechTranscriber (on-device)"
        }
    }

    static let storageKey = "kioku.transcription.engine"

    // Apple's SpeechTranscriber where the OS has it, Qwen3-ASR otherwise.
    static var current: TranscriptionEngine {
        if #available(iOS 26.0, *) { return .appleTranscriber }
        return .qwen3
    }
}
