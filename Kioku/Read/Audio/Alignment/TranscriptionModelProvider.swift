import Foundation
import OSLog

private let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "Transcription")

// Resolves the on-device Whisper model used for *transcription* (audio → text).
//
// Kept separate from the alignment model so transcription can run on Small while
// forced alignment stays on Base. The file lives in a `Transcription/` subdirectory
// that OnDeviceLyricAligner.bestAvailableModelURL (a non-recursive scan of the
// top-level WhisperModels directory) deliberately ignores — so downloading the
// transcription model never silently upgrades the aligner's model.
enum TranscriptionModelProvider {
    // Small: best-measured Whisper size for transcription (base under-resolves, medium
    // over-generates on hard audio). 466 MB.
    private static let model = WhisperDownloadableModel.all.first { $0.id == "small" }!

    static var directory: URL {
        WhisperModelManager.modelsDirectory.appendingPathComponent("Transcription", isDirectory: true)
    }

    static var modelURL: URL {
        directory.appendingPathComponent(model.filename)
    }

    static var isModelPresent: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    // Human-readable download size, for UI ("466 MB").
    static var downloadSizeText: String { "\(model.sizeMB) MB" }

    // Returns the local model URL, downloading it on first use. `onProgress` is called
    // off the main actor with a 0–1 fraction during download; callers marshal to the UI.
    static func ensureModel(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if isModelPresent { return modelURL }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logger.info("downloading transcription model \(model.filename) from \(model.remoteURL)")

        let delegate = TranscriptionDownloadProgressDelegate(onProgress: onProgress)
        let (tempURL, response) = try await URLSession.shared.download(from: model.remoteURL, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "Kioku.Transcription",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Transcription model download failed (HTTP \(status)). Check your connection and try again."]
            )
        }

        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: modelURL)
        logger.info("transcription model ready at \(modelURL.path)")
        return modelURL
    }
}

// Relays URLSession download progress to a closure. Mirrors the alignment downloader;
// kept local so the transcription model stays self-contained.
private final class TranscriptionDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards download progress to the onProgress closure as a 0–1 fraction.
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

    // Completion no-op — the file move is handled by the async download(from:delegate:) continuation.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}
