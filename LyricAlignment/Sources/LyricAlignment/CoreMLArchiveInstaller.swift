// CoreMLArchiveInstaller.swift
//
// First-run download + extraction shared by every zipped .mlmodelc this package fetches from the
// HF Hub (the MMS aligner, the HTDemucs isolator). A .mlmodelc is a directory bundle, so it ships
// as a .zip that is downloaded, extracted into [[ModelStorage]]'s purge-resistant Application
// Support tree, and health-checked by probing for model.mil inside the bundle.

import Foundation
import os

private let logger = Logger(subsystem: "LyricAlignment", category: "CoreMLArchiveInstaller")

// Hub coordinates and user-facing wording for one model archive.
struct CoreMLArchiveSpec: Sendable {
    let modelId: String
    // Commit SHA the archive is pinned to (docs/INVARIANTS.md, pinned model downloads).
    let revision: String
    let archiveName: String
    let modelDirName: String
    // Lower-case noun for HUD stage text ("Downloading isolator… 42%").
    let stageNoun: String
    // Sentence-case noun for error messages ("Vocal isolator download failed").
    let errorNoun: String
    let errorDomain: String
    // Download failure uses this code; a malformed archive uses errorCodeBase + 1.
    let errorCodeBase: Int
}

// Serializes installs so two callers needing the same model at once (alignment and stem
// transcription, or two first-run alignments) join one download instead of both passing the
// "missing" check and extracting over each other. Actor methods are re-entrant across `await`,
// so serializing needs the stored in-flight task, not just actor isolation.
actor CoreMLArchiveInstaller {
    static let shared = CoreMLArchiveInstaller()

    private var inFlight: [String: Task<URL, Error>] = [:]

    // Final on-disk location of the extracted .mlmodelc bundle for `spec`.
    nonisolated static func modelURL(for spec: CoreMLArchiveSpec) throws -> URL {
        try ModelStorage.directory(for: spec.modelId).appendingPathComponent(spec.modelDirName, isDirectory: true)
    }

    // Returns the installed bundle for `spec`, downloading and extracting it on first miss.
    // A second caller for the same model awaits the first caller's install.
    func ensure(_ spec: CoreMLArchiveSpec, onStage: (@Sendable (String) -> Void)?) async throws -> URL {
        if let running = inFlight[spec.modelId] { return try await running.value }
        let task = Task { try await Self.install(spec, onStage: onStage) }
        inFlight[spec.modelId] = task
        defer { inFlight[spec.modelId] = nil }
        return try await task.value
    }

    // Unserialized install: probe, wipe any half-extracted leftover, download, extract, re-probe.
    private static func install(_ spec: CoreMLArchiveSpec, onStage: (@Sendable (String) -> Void)?) async throws -> URL {
        let fm = FileManager.default
        let target = try modelURL(for: spec)
        // Probe inside the bundle so a half-extracted leftover from a crashed attempt reads as
        // "missing" and is retried rather than mistaken for a healthy install.
        let probe = target.appendingPathComponent("model.mil")
        if fm.fileExists(atPath: probe.path) { return target }
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }

        let archiveURL = URL(string: "https://huggingface.co/\(spec.modelId)/resolve/\(spec.revision)/\(spec.archiveName)")!
        logger.info("downloading \(spec.modelId) from \(archiveURL.absoluteString)")
        onStage?("Downloading \(spec.stageNoun)…")
        let delegate = ModelDownloadProgressDelegate { fraction in
            onStage?("Downloading \(spec.stageNoun)… \(Int((fraction * 100).rounded()))%")
        }
        let (tempURL, response) = try await URLSession.shared.download(from: archiveURL, delegate: delegate)
        defer { removeTemporaryDownload(tempURL) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw NSError(
                domain: spec.errorDomain,
                code: spec.errorCodeBase,
                userInfo: [NSLocalizedDescriptionKey: "\(spec.errorNoun) download failed (HTTP \(status)). Check your connection and try again."]
            )
        }

        onStage?("Extracting \(spec.stageNoun)…")
        let parent = try ModelStorage.directory(for: spec.modelId)
        let zipData = try Data(contentsOf: tempURL)
        try ZipExtractor.extract(zipData: zipData, to: parent)
        guard fm.fileExists(atPath: probe.path) else {
            throw NSError(
                domain: spec.errorDomain,
                code: spec.errorCodeBase + 1,
                userInfo: [NSLocalizedDescriptionKey: "\(spec.errorNoun) archive missing expected model.mil — archive contents do not match \(spec.modelDirName)."]
            )
        }
        logger.info("\(spec.modelId) ready at \(target.path)")
        return target
    }

    // Deletes the URLSession temp file. Failure only leaves a file in tmp/, which the OS reclaims,
    // so it is logged rather than thrown over the install's own result.
    private static func removeTemporaryDownload(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("could not remove temporary download \(url.path): \(error.localizedDescription)")
        }
    }
}
