import Foundation

// Failure surfaced when a capped download exceeds its ceiling.
enum BoundedDownloadError: LocalizedError {
    case tooLarge(maxBytes: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let maxBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
            return "The download is larger than the \(limit) limit."
        }
    }
}
