import Foundation

// Which version of the song the lyrics view plays: the original mix, the isolated vocal stem the
// aligner hears, or the mix with those vocals taken out. The stem-derived sources exist once the
// song has been aligned.
enum LyricsAudioSource: String {
    case mix
    case vocals
    case instrumental

    // The source the lyrics view's toggle moves to on the next tap, cycling Mix → Vocals → Instrumental.
    var next: LyricsAudioSource {
        switch self {
        case .mix: return .vocals
        case .vocals: return .instrumental
        case .instrumental: return .mix
        }
    }

    // Short name shown on the toggle.
    var label: String {
        switch self {
        case .mix: return "Mix"
        case .vocals: return "Vocals"
        case .instrumental: return "Instrumental"
        }
    }

    // SF Symbol shown on the toggle.
    var systemImage: String {
        switch self {
        case .mix: return "waveform"
        case .vocals: return "music.mic"
        case .instrumental: return "pianokeys"
        }
    }
}
