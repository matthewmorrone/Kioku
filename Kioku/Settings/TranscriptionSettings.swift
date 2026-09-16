import Foundation

// Engine used to turn an imported audio file into a note (audio → text). Qwen3-ASR is the only
// one selectable — a measured CER comparison (2026-09) showed it clearly beating both
// alternatives on real song audio (Apple Speech: 90.7% CER vs. Qwen3's 59.3-70.4%; Whisper
// crashed on-device before producing a result). appleSpeech/whisper stay as enum cases and their
// AudioTranscriptionService code paths are left in place, just unreachable — no UI selects them.
//
// This selects only the transcription engine; forced alignment stays on its own MMS model
// regardless (a separate pipeline, not user-selectable).
enum TranscriptionEngine: String, CaseIterable {
    case appleSpeech
    case whisper
    case qwen3

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper:     return "Whisper (on-device)"
        case .qwen3:       return "Qwen3-ASR (on-device)"
        }
    }

    static let storageKey = "kioku.transcription.engine"

    // Always Qwen3-ASR — no UI writes another value to storageKey anymore.
    static var current: TranscriptionEngine { .qwen3 }
}

// Whether to isolate the vocal stem before transcribing — orthogonal to the engine. ON (default) is
// best for songs (any recognizer sees clean vocals); OFF skips the memory-heavy HTDemucs isolation,
// which is right for plain speech and the guaranteed-light path (OFF + Apple Speech).
enum TranscriptionPreprocessing {
    static let isolateVocalsKey = "kioku.transcription.isolateVocals"
    static var isolateVocals: Bool {
        UserDefaults.standard.object(forKey: isolateVocalsKey) as? Bool ?? true
    }
}
