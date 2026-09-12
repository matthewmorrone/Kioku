// MMSModelStore.swift
//
// First-run download + on-disk cache for MMSForcedAligner.mlmodelc — Meta's MMS forced
// aligner (wav2vec2 + CTC over a romanized alphabet), exported to CoreML at fp16. Same shape
// as [[HTDemucsModelStore]]: the archive is a zipped .mlmodelc directory bundle on the HF Hub,
// extracted into [[ModelStorage]]'s purge-resistant Application Support tree.

import Foundation
import os

private let logger = Logger(subsystem: "SwiftWhisperAlign", category: "MMSModelStore")

public enum MMSModelStore {
    public static let modelId = "matthewmorrone/MMS-ForcedAligner-CoreML"
    // Pin to a commit once the archive is uploaded; a moving branch means a future force-push
    // silently changes the bytes every install receives.
    public static let revision = "main"
    public static let archiveName = "MMSForcedAligner.mlmodelc.zip"
    public static let modelDirName = "MMSForcedAligner.mlmodelc"

    private static var archiveURL: URL {
        URL(string: "https://huggingface.co/\(modelId)/resolve/\(revision)/\(archiveName)")!
    }

    // Final on-disk location of the extracted .mlmodelc bundle.
    public static func modelURL() throws -> URL {
        try ModelStorage.directory(for: modelId).appendingPathComponent(modelDirName, isDirectory: true)
    }

    // Serializes concurrent ensureModel() callers so two first-run alignments can't race one
    // download/extraction against the other.
    private actor InstallCoordinator {
        static let shared = InstallCoordinator()
        func run(_ operation: @escaping @Sendable () async throws -> URL) async throws -> URL {
            try await operation()
        }
    }

    // Ensures MMSForcedAligner.mlmodelc is present, downloading + extracting on first miss.
    // A sideloaded copy under <App Documents>/MMSForcedAligner.mlmodelc wins when present —
    // the development path while the archive isn't published yet.
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        try await InstallCoordinator.shared.run {
            try await ensureModelUnguarded(onStage: onStage)
        }
    }

    private static func ensureModelUnguarded(onStage: (@Sendable (String) -> Void)?) async throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let sideloaded = docs.appendingPathComponent(modelDirName, isDirectory: true)
        if fm.fileExists(atPath: sideloaded.appendingPathComponent("model.mil").path) {
            return sideloaded
        }

        let target = try modelURL()
        // Probe inside the bundle so a half-extracted leftover from a crashed attempt reads as
        // "missing" and is retried rather than mistaken for a healthy install.
        let probe = target.appendingPathComponent("model.mil")
        if fm.fileExists(atPath: probe.path) { return target }
        try? fm.removeItem(at: target)

        logger.info("downloading MMS forced aligner from \(archiveURL.absoluteString)")
        onStage?("Downloading aligner…")
        let delegate = HTDemucsDownloadProgressDelegate { fraction in
            onStage?("Downloading aligner… \(Int((fraction * 100).rounded()))%")
        }
        let (tempURL, response) = try await URLSession.shared.download(from: archiveURL, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? fm.removeItem(at: tempURL)
            throw NSError(domain: "SwiftWhisperAlign.MMS", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "Aligner download failed (HTTP \(status)). Check your connection and try again."])
        }

        onStage?("Extracting aligner…")
        let parent = try ModelStorage.directory(for: modelId)
        let zipData = try Data(contentsOf: tempURL)
        try? fm.removeItem(at: tempURL)
        try ZipExtractor.extract(zipData: zipData, to: parent)
        guard fm.fileExists(atPath: probe.path) else {
            throw NSError(domain: "SwiftWhisperAlign.MMS", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "Aligner archive missing expected model.mil — archive contents do not match MMSModelStore.modelDirName."])
        }
        logger.info("MMS forced aligner ready at \(target.path)")
        return target
    }
}
