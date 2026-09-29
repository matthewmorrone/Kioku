// ModelDownloadProgressDelegate.swift

import Foundation

// Bridges URLSession's download-progress callback to a Swift closure for the .mlmodelc archive
// downloads in [[CoreMLArchiveInstaller]].
final class ModelDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    // Captures the progress callback for the lifetime of the download task.
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards bytes-written / bytes-expected to the closure as a 0–1 fraction. A server that
    // sends no Content-Length reports -1 here, which would render as a nonsense percentage.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the delegate protocol; the file move is handled by the async
    // download(from:delegate:) continuation, so nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
