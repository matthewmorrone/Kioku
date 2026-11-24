import Foundation

// Why a YouTube audio download could not complete; each case carries the message the alignment-failure
// alert shows.
enum YouTubeAudioFailure: LocalizedError {
    case unplayable(String)
    case noAudioStream
    case badResponse(Int)

    // The text shown to the user for this failure.
    var errorDescription: String? {
        switch self {
        case .unplayable(let reason): return "YouTube won't give out this video's audio: \(reason)"
        case .noAudioStream: return "YouTube listed no downloadable audio for this video."
        case .badResponse(let code): return "YouTube refused the audio download (HTTP \(code))."
        }
    }
}
