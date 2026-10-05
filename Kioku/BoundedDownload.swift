import Foundation

// Fetches a remote body with a hard byte ceiling. URLSession.data(from:) buffers whatever the
// server sends, so a hostile or broken host can exhaust memory before any content check runs;
// this streams the body and stops as soon as the ceiling is crossed. Shared by URL import and
// subtitle downloads, the two paths that fetch arbitrary user-reachable URLs.
nonisolated enum BoundedDownload {

    // Returns the body and response, throwing BoundedDownloadError.tooLarge when either the
    // declared Content-Length or the bytes actually received exceed `maxBytes`.
    static func data(from url: URL, maxBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        // Reject up front when the server already admits the body is too big.
        if response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw BoundedDownloadError.tooLarge(maxBytes: maxBytes)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            // Content-Length can lie or be absent; the received count is what's enforced.
            guard data.count < maxBytes else {
                bytes.task.cancel()
                throw BoundedDownloadError.tooLarge(maxBytes: maxBytes)
            }
            data.append(byte)
        }
        return (data, response)
    }
}
