// HTDemucsFTDownloader.swift
//
// Plain-URLSession file download used by CTCForcedAligner's HTDemucs-FT isolation step.
// See the call site's comment for why this bypasses HTDemucsSeparator.fromPretrained's
// HubApi-based downloader (frozen progress text on-device, and a stall against the file's
// Xet-CDN redirect).

import Foundation

enum HTDemucsFTDownloader {
    // Downloads one file to `destination`, reporting 0–1 progress. Overwrites any existing
    // file at the destination (callers already gate on absence before calling). `expectedBytes`
    // is a fallback denominator for when the response doesn't carry a size URLSession recognizes
    // (observed on-device against this file's Xet-CDN redirect: didWriteData's
    // totalBytesExpectedToWrite came back -1 for the whole transfer, so every progress callback
    // was silently dropped and the UI sat at "0%" for the ~3.5 min download despite it
    // proceeding fine in the background).
    static func downloadFile(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let delegate = HTDemucsFTDownloadProgressDelegate(expectedBytes: expectedBytes, onProgress: onProgress ?? { _ in })
        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "SwiftWhisperAlign.HTDemucsFT",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Vocal isolator download failed (HTTP \(status)) for \(url.lastPathComponent)."]
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}

// Bridges URLSession's download-progress callback to a Swift closure. Mirrors
// HTDemucsModelStore's delegate of the same shape, kept separate since it targets a
// different model (MLX safetensors, not the CoreML .mlmodelc archive).
private final class HTDemucsFTDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64?
    private let onProgress: @Sendable (Double) -> Void

    // Captures the progress callback for the lifetime of the download task.
    init(expectedBytes: Int64?, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    // Forwards bytes-written / bytes-expected to the closure as a 0–1 fraction. Falls back to
    // the caller-supplied `expectedBytes` when the response doesn't carry a size URLSession
    // recognizes (totalBytesExpectedToWrite <= 0) — see downloadFile's doc comment.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedBytes ?? 0)
        guard total > 0 else { return }
        onProgress(min(1.0, Double(totalBytesWritten) / Double(total)))
    }

    // Required by the delegate protocol; the file move is handled by the async
    // download(from:delegate:) continuation, so nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
