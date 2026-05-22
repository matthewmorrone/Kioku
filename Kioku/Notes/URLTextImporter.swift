import Foundation
import UIKit

// Fetches a URL and extracts its main text content into something Kioku can ingest as a Note.
// Uses NSAttributedString's HTML document-type initializer — iOS's built-in HTML→text path —
// rather than a full DOM parser, which is good enough for article-like pages (NHK News Easy,
// blog posts, etc.) and avoids the complexity of bundling a Readability-style extractor.
nonisolated enum URLTextImporter {

    enum ImportError: LocalizedError {
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

    // Fetches the URL, parses the HTML, and returns the visible text as a single trimmed string.
    static func extractText(from urlString: String) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { throw ImportError.invalidURL }
        if components.scheme == nil {
            components.scheme = "https"
        }
        guard let url = components.url, let scheme = url.scheme, scheme.hasPrefix("http") else {
            throw ImportError.invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ImportError.fetchFailed(underlying: error)
        }

        // Only proceed for HTML/text MIME types — we'd produce gibberish on PDFs or images.
        if let mime = (response as? HTTPURLResponse)?.mimeType,
           mime.hasPrefix("text/") == false,
           mime != "application/xhtml+xml" {
            throw ImportError.nonHTMLResponse(mimeType: mime)
        }

        let extracted = await Task.detached(priority: .userInitiated) {
            extractPlainText(from: data)
        }.value

        guard let text = extracted, text.isEmpty == false else { throw ImportError.emptyResult }
        return text
    }

    // Synchronous HTML→plain-text conversion. Runs on a background queue when called from
    // `extractText(from:)`. Returns nil if the data can't be parsed as HTML at all.
    static func extractPlainText(from data: Data) -> String? {
        // NSAttributedString options for HTML documents. characterEncoding default works fine for
        // UTF-8 pages; pages declaring other encodings via meta tags are handled by the parser.
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        let raw = attributed.string
        // Collapse runs of blank lines that the HTML parser leaves behind between blocks.
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Drop adjacent duplicate-blank lines while preserving paragraph breaks.
        var compressed: [String] = []
        var sawBlank = false
        for line in lines {
            if line.isEmpty {
                if sawBlank == false { compressed.append("") }
                sawBlank = true
            } else {
                compressed.append(line)
                sawBlank = false
            }
        }
        return compressed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
