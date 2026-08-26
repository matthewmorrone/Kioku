import Foundation

// Failure states SongListenAudioService.renderAudio can throw. Its own file (rather than
// nested in the service) per the repo's no-nested-types rule, since it carries a computed
// property. `nonisolated` since it's thrown from the `nonisolated` SongListenAudioService —
// without it, the module's default MainActor isolation would make `errorDescription`
// MainActor-isolated.
nonisolated enum SongListenRenderError: Error, LocalizedError {
    case emptyScript
    case noAudioProduced
    case voiceUnavailable
    case clipReadFailed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .emptyScript: return "This breakdown has nothing to read aloud yet."
        case .noAudioProduced: return "Speech synthesis produced no audio."
        case .voiceUnavailable: return "This device doesn't have the Japanese and English voices needed for listen-along audio."
        case .clipReadFailed: return "Couldn't read the song's audio for one of its lines."
        case .conversionFailed: return "Couldn't prepare the audio for the listen-along track."
        }
    }
}
