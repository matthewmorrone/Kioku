import Foundation

// Failure cases surfaced by URLTextImporter's fetch-and-extract pipeline.
nonisolated enum URLTextImporterError: LocalizedError {
    case invalidURL
    case fetchFailed(underlying: Error)
    case nonHTMLResponse(mimeType: String?)
    case decodingFailed
    case emptyResult

    // Human-readable error strings used in the UI's failure alert.
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid URL."
        case .fetchFailed(let underlying): return "Couldn't fetch the URL: \(underlying.localizedDescription)"
        case .nonHTMLResponse(let mime): return "Expected an HTML page; got \(mime ?? "unknown content type")."
        case .decodingFailed: return "Couldn't decode the page's HTML."
        case .emptyResult: return "The page didn't contain any extractable text."
        }
    }
}
