import Foundation

// Why a segmentation correction couldn't be used: the model's compact-format half had nothing
// parseable (see LLMCorrectionFormat.parseCompactResponse), or it didn't reconstruct the note
// text when staged.
enum LLMCorrectionError: LocalizedError {
    case decodingError(String)

    // Human-readable message surfaced in the UI alert.
    var errorDescription: String? {
        switch self {
        case .decodingError(let msg):
            return "Could not parse response: \(msg)"
        }
    }
}
