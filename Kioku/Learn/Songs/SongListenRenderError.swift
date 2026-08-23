import Foundation

// Failure states SongListenAudioService.renderAudio can throw. Its own file (rather than
// nested in the service) per the repo's no-nested-types rule, since it carries a computed
// property.
enum SongListenRenderError: Error, LocalizedError {
    case emptyScript
    case noAudioProduced

    var errorDescription: String? {
        switch self {
        case .emptyScript: return "This breakdown has nothing to read aloud yet."
        case .noAudioProduced: return "Speech synthesis produced no audio."
        }
    }
}
