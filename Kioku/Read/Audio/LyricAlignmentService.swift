import Foundation
import UniformTypeIdentifiers

// Uploads one audio file and a lyrics payload to the configured alignment endpoint and returns raw SRT text.
enum LyricAlignmentService {
    private static let requestTimeout: TimeInterval = 60 * 10
    private static let resourceTimeout: TimeInterval = 60 * 30
    private static let maxAttempts = 3

    static func align(
        audioURL: URL,
        lyrics: String,
        configuration: LyricAlignmentSettings.Configuration
    ) async throws -> String {
        let didStartAccess = audioURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                audioURL.stopAccessingSecurityScopedResource()
            }
        }

        let boundary = "KiokuBoundary-\(UUID().uuidString)"
        let filename = audioURL.lastPathComponent.isEmpty ? "audio.mp3" : audioURL.lastPathComponent
        let mimeType = UTType(filenameExtension: audioURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let requestBodyURL = try createMultipartRequestBodyFile(
            boundary: boundary,
            audioURL: audioURL,
            audioFilename: filename,
            audioMimeType: mimeType,
            lyrics: lyrics,
            language: configuration.language
        )
        defer {
            try? FileManager.default.removeItem(at: requestBodyURL)
        }
        let requestBodySize = (try? requestBodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-subrip, text/plain; q=0.9, */*; q=0.1", forHTTPHeaderField: "Accept")
        request.setValue(String(requestBodySize), forHTTPHeaderField: "Content-Length")
        if requestBodySize >= 256 * 1024 {
            request.setValue("100-continue", forHTTPHeaderField: "Expect")
        }

        let (data, response) = try await performUpload(
            request: request,
            bodyFileURL: requestBodyURL
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The alignment server returned an invalid response."]
            )
        }

        let responseText = decodeResponseText(data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let fallback = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            let message = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: message.isEmpty
                        ? "Alignment failed (\(httpResponse.statusCode)): \(fallback)"
                        : "Alignment failed (\(httpResponse.statusCode)): \(message)"
                ]
            )
        }

        let trimmedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The alignment server returned an empty SRT response."]
            )
        }

        return trimmedText
    }

    private static func performUpload(
        request: URLRequest,
        bodyFileURL: URL
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            let session = makeSession()
            do {
                let result = try await session.upload(for: request, fromFile: bodyFileURL)
                session.finishTasksAndInvalidate()
                return result
            } catch let error as URLError {
                session.invalidateAndCancel()
                lastError = error
                guard shouldRetry(error), attempt < maxAttempts else {
                    throw mapNetworkError(error)
                }

                let backoffNanoseconds = UInt64(attempt) * 750_000_000
                try? await Task.sleep(nanoseconds: backoffNanoseconds)
            } catch {
                session.invalidateAndCancel()
                throw error
            }
        }

        throw lastError ?? NSError(
            domain: "Kioku.LyricAlignment",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Alignment failed before the request could complete."]
        )
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func mapNetworkError(_ error: URLError) -> NSError {
        let message: String
        switch error.code {
        case .timedOut:
            message = "Alignment timed out after 10 minutes. The server may still be processing, or the upload may be too slow."
        case .networkConnectionLost:
            message = "The network connection to the alignment server was lost during upload. Kioku will retry automatically, but if this keeps happening the server is closing the connection before the upload finishes."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            message = "Could not reach the alignment server. Check the Lyric Alignment settings and confirm the server is running."
        default:
            message = error.localizedDescription
        }

        return NSError(
            domain: "Kioku.LyricAlignment",
            code: error.errorCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private static func makeTemporaryFileURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    private static func createMultipartRequestBodyFile(
        boundary: String,
        audioURL: URL,
        audioFilename: String,
        audioMimeType: String,
        lyrics: String,
        language: String
    ) throws -> URL {
        let bodyFileURL = makeTemporaryFileURL(extension: "multipart")
        FileManager.default.createFile(atPath: bodyFileURL.path, contents: nil)

        let bodyHandle = try FileHandle(forWritingTo: bodyFileURL)
        defer {
            try? bodyHandle.close()
        }

        try bodyHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(sanitizedMultipartFilename(audioFilename))\"\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("Content-Type: \(audioMimeType)\r\n\r\n".utf8))

        let audioHandle = try FileHandle(forReadingFrom: audioURL)
        defer {
            try? audioHandle.close()
        }

        var chunk = try audioHandle.read(upToCount: 64 * 1024) ?? Data()
        while chunk.isEmpty == false {
            try bodyHandle.write(contentsOf: chunk)
            chunk = try audioHandle.read(upToCount: 64 * 1024) ?? Data()
        }

        try bodyHandle.write(contentsOf: Data("\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"lyrics\"\r\n\r\n".utf8))
        try bodyHandle.write(contentsOf: Data(lyrics.utf8))
        try bodyHandle.write(contentsOf: Data("\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
        try bodyHandle.write(contentsOf: Data(language.utf8))
        try bodyHandle.write(contentsOf: Data("\r\n".utf8))
        try bodyHandle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))

        return bodyFileURL
    }

    private static func sanitizedMultipartFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "audio.mp3" : cleaned
    }

    private static func decodeResponseText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }
}
