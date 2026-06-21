import Foundation

// Engine used to turn an imported audio file into a note (audio → text).
//
// Apple Speech (SFSpeechRecognizer) is the default: near real-time and strong on
// clean spoken Japanese. Whisper (on-device, Small model) is slower but holds up
// better on noisy/hard audio. Small is chosen deliberately — measured CER on a song
// was base 137% / small 64% / medium 89%, i.e. Small beats both base and medium
// (larger models over-generate on non-speech). See project_audio_capability_findings.
//
// This selects only the transcription engine; forced alignment stays on the Base
// model regardless (its model lives in a separate directory).
enum TranscriptionEngine: String, CaseIterable {
    case appleSpeech
    case whisper
    // Qwen3-ASR (0.6B, on-device MLX) — the same checkpoint that powers forced alignment, far
    // stronger on Japanese than Whisper-Small or Apple Speech. Default engine.
    case qwen3

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper:     return "Whisper (Small, on-device)"
        case .qwen3:       return "Qwen3-ASR (on-device)"
        }
    }

    static let storageKey = "kioku.transcription.engine"

    // Reads the user's current choice from UserDefaults (defaults to Qwen3-ASR).
    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .qwen3
    }
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
