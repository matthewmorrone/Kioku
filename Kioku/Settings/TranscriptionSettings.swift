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

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper:     return "Whisper (Small, on-device)"
        }
    }

    static let storageKey = "kioku.transcription.engine"

    // Reads the user's current choice from UserDefaults (defaults to Apple Speech).
    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .appleSpeech
    }
}
