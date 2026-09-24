import Foundation

// Engine used to turn an imported audio file into a note (audio → text). Not user-selectable:
// Apple's SpeechTranscriber on iOS 26+ (4.9% character error on FLEURS Japanese speech vs
// Qwen3-ASR's 11.6%, 2026-09-23), Qwen3-ASR below that. appleSpeech (the older SFSpeechRecognizer,
// 90.7% on songs) and whisper (crashed on-device) stay as cases whose AudioTranscriptionService
// paths are unreachable.
//
// This selects only the transcription engine; forced alignment stays on its own MMS model
// regardless (a separate pipeline, not user-selectable).
enum TranscriptionEngine: String, CaseIterable {
    case appleSpeech
    case whisper
    case qwen3
    case appleTranscriber

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper:     return "Whisper (on-device)"
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
