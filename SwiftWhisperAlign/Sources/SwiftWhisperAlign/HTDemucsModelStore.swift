// HTDemucsModelStore.swift
// First-run download + on-disk cache for HTDemucsSpec.mlmodelc — the CoreML vocal isolator
// CTCForcedAligner runs before forced alignment. The model is 269 MB uncompressed, hosted
// as a single .zip on HuggingFace; the SDK's fromPretrained() can't fetch it because the
// .mlmodelc is a directory bundle (model.mil + weights/ + metadata), not a flat MLX
// safetensors layout — so we drive the download + extract ourselves.
//
// Cache lives under [[ModelStorage]]'s Application Support tree (same purge-resistant,
// off-iCloud-backup placement as the ASR + CTC aligner weights), so a future reinstall
// is the only event that wipes it — and reinstall self-heals on the next align run.

import Foundation
import OSLog

private let logger = Logger(subsystem: "matthewmorrone.SwiftWhisperAlign", category: "HTDemucsModelStore")

public enum HTDemucsModelStore {
    // HF Hub coordinates. `revision` is pinned to the commit SHA of the upload (NOT `main`)
    // so a future hub-side edit or tag move can't silently swap the model bytes shipping with
    // installs — same discipline as WhisperDownloadableModel.pinnedRevision. Bump this any
    // time the model is republished.
    public static let modelId = "matthewmorrone/HTDemucs-CoreML"
    public static let revision = "1814775e602778cc093cb23138d773645166d724"
    public static let archiveName = "HTDemucsSpec.mlmodelc.zip"
    public static let modelDirName = "HTDemucsSpec.mlmodelc"

    // The signed URL the model archive is fetched from on first run.
    private static var archiveURL: URL {
        URL(string: "https://huggingface.co/\(modelId)/resolve/\(revision)/\(archiveName)")!
    }

    // Final on-disk location of the extracted .mlmodelc bundle. Reusing [[ModelStorage]]
    // means HTDemucs ends up next to the ASR + CTC weights — one cache, one purge policy.
    public static func modelURL() throws -> URL {
        try ModelStorage.directory(for: modelId).appendingPathComponent(modelDirName, isDirectory: true)
    }

    // Ensures HTDemucsSpec.mlmodelc is present at the model URL, downloading + extracting
    // the archive on first miss. Idempotent: subsequent calls no-op once the bundle is
    // on disk. `onStage` reports human-readable phase text the alignment HUD already
    // surfaces ("Downloading vocal isolator… 42%", "Extracting vocal isolator…").
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        // DIAGNOSTIC FALLBACK: a sideloaded copy under <App Documents>/HTDemucsSpec.mlmodelc
        // is preferred when present. CoreML's on-load device-specialization passes that worked
        // from the Documents path on 2026-06-19 / -24 started SIGKILLing once the model moved
        // to Application Support (same bytes, different location). Until that's diagnosed, the
        // sideload escape hatch keeps SRT generation working on devices where Documents is OK.
        // Drop this branch once CoreML succeeds from the Application Support path.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyURL = docs.appendingPathComponent("HTDemucsSpec.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("model.mil").path) {
            return legacyURL
        }

        let target = try modelURL()
        // Health probe: model.mil is the largest must-have file inside the .mlmodelc bundle.
        // Probing inside the directory (not just the directory's existence) means a
        // half-extracted leftover from a crashed prior attempt is treated as "missing"
        // and retried, instead of being mistaken for a healthy install.
        let probe = target.appendingPathComponent("model.mil")
        if FileManager.default.fileExists(atPath: probe.path) {
            return target
        }

        // Wipe any half-extracted directory before re-fetching so partial state from a
        // previous crash can't poison the fresh download.
        try? FileManager.default.removeItem(at: target)

        logger.info("downloading HTDemucs CoreML model from \(archiveURL.absoluteString)")
        onStage?("Downloading isolator…")

        let delegate = HTDemucsDownloadProgressDelegate { fraction in
            let pct = Int((fraction * 100).rounded())
            onStage?("Downloading isolator… \(pct)%")
        }
        let (tempURL, response) = try await URLSession.shared.download(from: archiveURL, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "SwiftWhisperAlign.HTDemucs",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Vocal isolator download failed (HTTP \(status)). Check your connection and try again."]
            )
        }

        onStage?("Extracting isolator…")
        let parent = try ModelStorage.directory(for: modelId)
        let zipData = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        try ZipExtractor.extract(zipData: zipData, to: parent)

        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw NSError(
                domain: "SwiftWhisperAlign.HTDemucs",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: "Vocal isolator archive missing expected model.mil — archive contents do not match HTDemucsModelStore.modelDirName."]
            )
        }
        logger.info("HTDemucs CoreML model ready at \(target.path)")
        return target
    }
}

// Bridges URLSession's download-progress callback to a Swift closure. Kept module-private
// because the model archive download is the only place in SwiftWhisperAlign that needs
// progress-driven URLSession.
private final class HTDemucsDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    // Captures the progress callback for the lifetime of the download task.
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards bytes-written / bytes-expected to the closure as a 0–1 fraction.
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
