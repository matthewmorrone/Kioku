// OnDeviceLyricAligner.swift
// Drives the on-device forced-alignment pipeline:
//   1. Ensure a GGML Whisper model + Core ML encoder are present,
//      downloading them automatically if needed.
//   2. Force-align input lyric lines to audio using whisper.cpp's
//      logits_filter_callback (via SwiftWhisperAlign).
//   3. Emit SRT text (SRTWriter).
//
// Models are downloaded from huggingface.co/ggerganov/whisper.cpp and stored
// in the app support directory managed by WhisperModelManager.

import Foundation
import OSLog
import SwiftWhisperAlign
#if canImport(UIKit)
import UIKit
#endif

// Subsystem-tagged so Console.app filtering ("subsystem:matthewmorrone.Kioku
// category:OnDeviceAlign") shows only alignment pipeline output.
private let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "OnDeviceAlign")

// Entry point for on-device lyric alignment.
enum OnDeviceLyricAligner {

    // The model downloaded automatically when none is present.
    // "base" (142 MB) gives meaningfully better DTW cross-attention structure than
    // "tiny" (75 MB) — tiny's attention heads produce visibly noisier per-token
    // timestamps under forced alignment. Users can still download larger models
    // from Settings → Whisper Models for higher accuracy.
    private static let defaultModel = WhisperDownloadableModel(
        id: "base",
        displayName: "Base",
        filename: "ggml-base.bin",
        parameters: "74M",
        sizeMB: 142
    )

    // Returns the best available downloaded GGML model URL, preferring
    // higher-quality models. Returns nil if no model has been downloaded yet.
    static func bestAvailableModelURL() -> URL? {
        let dir = WhisperModelManager.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            logger.error("models directory not found at \(dir.path)")
            return nil
        }

        let preferenceOrder = ["ggml-medium.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"]
        let binFiles = files.filter { $0.hasSuffix(".bin") }
        logger.info("found \(binFiles.count) model(s): \(binFiles.sorted().joined(separator: ", "))")
        guard binFiles.isEmpty == false else { return nil }

        for preferred in preferenceOrder {
            if binFiles.contains(preferred) {
                logger.info("selected model: \(preferred)")
                return dir.appendingPathComponent(preferred)
            }
        }
        let fallback = binFiles.sorted().first!
        logger.info("selected model (fallback): \(fallback)")
        return dir.appendingPathComponent(fallback)
    }

    // Returns the expected Core ML encoder directory URL for a given model bin URL.
    // whisper.cpp derives this path by replacing ".bin" with "-encoder.mlmodelc".
    static func coreMLEncoderURL(for modelURL: URL) -> URL {
        let base = modelURL.deletingPathExtension().lastPathComponent
        return modelURL.deletingLastPathComponent()
            .appendingPathComponent("\(base)-encoder.mlmodelc")
    }

    // Downloads the default model (bin + Core ML encoder) if not already present.
    // onProgress receives human-readable status strings suitable for the UI,
    // called on the main queue throughout.
    // Returns the local URL of the downloaded GGML model.
    static func downloadDefaultModel(onProgress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let model = defaultModel
        let dir = WhisperModelManager.modelsDirectory
        let destination = dir.appendingPathComponent(model.filename)

        if FileManager.default.fileExists(atPath: destination.path) == false {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await MainActor.run { onProgress("Downloading Whisper model (0%)...") }

            let delegate = WhisperAlignmentDownloadDelegate { fraction in
                let pct = Int((fraction * 100).rounded())
                Task { @MainActor in onProgress("Downloading Whisper model (\(pct)%)...") }
            }

            let (tempURL, response) = try await URLSession.shared.download(from: model.remoteURL, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                try? FileManager.default.removeItem(at: tempURL)
                throw NSError(
                    domain: "Kioku.OnDeviceAlignment",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Model download failed (HTTP \(status)). Check your internet connection and try again."]
                )
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            logger.info("GGML model saved to \(destination.path)")
        }

        // Always ensure the Core ML encoder is present so inference uses the Neural Engine.
        await ensureCoreMLEncoder(forModelAt: destination, onProgress: onProgress)

        await MainActor.run { onProgress("Model ready.") }
        return destination
    }

    // Downloads the Core ML encoder zip for an existing GGML model if it is missing,
    // then extracts it alongside the .bin file so whisper.cpp can load it.
    //
    // HuggingFace stores the encoder as "ggml-{name}-encoder.mlmodelc.zip" in the
    // ggerganov/whisper.cpp repo. We download that single file and extract it using
    // ZipExtractor (raw inflate via system libz, no external dependency needed).
    //
    // Never throws — falls back to CPU if the download or extraction fails.
    static func ensureCoreMLEncoder(
        forModelAt modelURL: URL,
        onProgress: @escaping @MainActor (String) -> Void
    ) async {
        let encoderDir = coreMLEncoderURL(for: modelURL)
        guard FileManager.default.fileExists(atPath: encoderDir.path) == false else {
            logger.debug("Core ML encoder already present: \(encoderDir.lastPathComponent)")
            return
        }

        // Derive the zip filename, e.g. "ggml-base-encoder.mlmodelc.zip"
        // Pinned to the same immutable commit as the GGML model downloads so the
        // encoder bytes cannot change out from under shipped installs.
        let zipName = encoderDir.lastPathComponent + ".zip"
        guard let zipURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(WhisperDownloadableModel.pinnedRevision)/\(zipName)") else {
            return
        }

        logger.info("downloading Core ML encoder: \(zipName)")
        await MainActor.run { onProgress("Downloading Core ML model...") }

        do {
            let delegate = WhisperAlignmentDownloadDelegate { fraction in
                let pct = Int((fraction * 100).rounded())
                Task { @MainActor in onProgress("Downloading Core ML model (\(pct)%)...") }
            }

            let (tempZipURL, response) = try await URLSession.shared.download(from: zipURL, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                try? FileManager.default.removeItem(at: tempZipURL)
                logger.warning("HTTP \(status) for \(zipName); will use CPU fallback")
                return
            }

            await MainActor.run { onProgress("Extracting Core ML model...") }

            // Load the zip into memory and extract. The .mlmodelc.zip from HuggingFace
            // contains the directory as "ggml-{name}-encoder.mlmodelc/..." entries, which
            // ZipExtractor places directly inside the models directory.
            let modelsDir = modelURL.deletingLastPathComponent()
            let zipData = try Data(contentsOf: tempZipURL)
            try? FileManager.default.removeItem(at: tempZipURL)
            try ZipExtractor.extract(zipData: zipData, to: modelsDir)

            if FileManager.default.fileExists(atPath: encoderDir.path) {
                logger.info("Core ML encoder ready: \(encoderDir.path)")
            } else {
                logger.warning("extraction succeeded but encoder dir not found — zip structure may differ")
            }
        } catch {
            logger.error("Core ML encoder download/extraction failed: \(error.localizedDescription); will use CPU fallback")
        }
    }

    // Force-aligns input lyric lines to audio using whisper.cpp's logits filter callback.
    // The model is used purely as a timing engine — it emits only the provided lyric tokens.
    // Non-speech gaps are inferred from timing gaps between lines.
    //
    // lyrics: the full note text (will be split on newlines; blank lines are skipped).
    // modelURL: path to a GGML .bin file.
    // onProgress: called on main queue with a 0–1 fraction as Whisper processes audio.
    // onSegment: called each time a segment completes with partial aligned lines.
    // cancellationCheck: polled during inference; return true to abort.
    static func align(
        audioURL: URL,
        lyrics: String,
        modelURL: URL,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([SwiftWhisperAlign.AlignedLine]) -> Void)? = nil
    ) async throws -> String {

        let lines = lyrics
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard lines.isEmpty == false else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align. Add lyrics to the note before generating subtitles."]
            )
        }

        logger.info("force-aligning \(lines.count) line(s) via CTC")

        let input = AlignmentInput(audioURL: audioURL, lines: lines)

        // Hold a background-task assertion across the CTC pass. If the app is
        // backgrounded mid-alignment (screen lock / app switch), iOS otherwise
        // SIGKILLs it (RUNNINGBOARD 0xDEAD10CC) for holding a resource lock while
        // suspending. This buys the seconds the on-device compute needs.
        #if canImport(UIKit)
        let bg = await BackgroundTaskHolder.begin("kioku.lyric-alignment")
        defer { bg.endDetached() }
        #endif

        // DTW (Whisper cross-attention) collapsed on full songs (~101s median error
        // vs the stable-ts oracle, 0% within ±500ms). Replaced by the CTC forced
        // aligner (soniqo Qwen3ForcedAligner): ~3.9s median on the vocal stem, 26×
        // better. `modelURL` is now unused (CTC downloads its own model via
        // fromPretrained); kept in the signature for call-site stability. To revert,
        // uncomment the ForcedAligner block below and comment out the CTC call.
        // let aligner = ForcedAligner(modelURL: modelURL)
        // let srt = try await aligner.alignToSRT(
        //     input: input,
        //     cancellationCheck: cancellationCheck,
        //     onProgress: onProgress,
        //     onSegment: onSegment
        // )
        let srt = try await CTCForcedAligner().alignToSRT(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onStage: onStage,
            onSegment: onSegment
        )

        logger.info("alignment complete")
        return srt
    }

    // Whole-note force-alignment that returns the STRUCTURED result (per-line timings + per-unit
    // sub-line checkpoints) instead of flattened SRT text. The caller builds cues directly from
    // this so the karaoke checkpoints survive — an SRT round-trip is line-level and drops them,
    // which is why whole-note Re-align used to highlight only per-line. Mirrors `align`'s setup
    // (line filtering, background-task assertion); `modelURL` is unused by the CTC path (kept for
    // call-site parity).
    static func alignDetailed(
        audioURL: URL,
        lyrics: String,
        modelURL: URL,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([SwiftWhisperAlign.AlignedLine]) -> Void)? = nil
    ) async throws -> SwiftWhisperAlign.AlignmentResult {
        let lines = lyrics
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard lines.isEmpty == false else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align. Add lyrics to the note before generating subtitles."]
            )
        }

        logger.info("force-aligning \(lines.count) line(s) via CTC (detailed)")
        let input = AlignmentInput(audioURL: audioURL, lines: lines)

        #if canImport(UIKit)
        let bg = await BackgroundTaskHolder.begin("kioku.lyric-alignment")
        defer { bg.endDetached() }
        #endif

        let result = try await CTCForcedAligner().align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: nil,
            onStage: onStage,
            onSegment: onSegment
        )
        logger.info("alignment complete (detailed): \(result.lines.count) lines")
        return result
    }

    // Re-aligns a SINGLE lyric line against a bounded window of the audio, returning the
    // line-level timing plus per-token checkpoints. Backs the lyric view's in-place "fix
    // this line's word sweep" control: the caller passes a padded window around the cue's
    // current bounds so the forced decoder only has to place this one line within a few
    // seconds of audio. Mirrors `align` but keeps per-token granularity.
    static func realignLine(
        audioURL: URL,
        line: String,
        windowStartSeconds: Double,
        windowEndSeconds: Double,
        modelURL: URL,
        cancellationCheck: (@Sendable () -> Bool)? = nil
    ) async throws -> SwiftWhisperAlign.AlignedLineTokens {
        let windowDesc = String(format: "[%.1fs, %.1fs]", windowStartSeconds, windowEndSeconds)
        logger.info("re-aligning one line over \(windowDesc) using \(modelURL.lastPathComponent)")
        let aligner = ForcedAligner(modelURL: modelURL)
        return try await aligner.alignSingleLine(
            audioURL: audioURL,
            line: line,
            windowStartSeconds: windowStartSeconds,
            windowEndSeconds: windowEndSeconds,
            cancellationCheck: cancellationCheck
        )
    }
}

// URLSession download delegate that forwards byte-level progress to a closure.
private final class WhisperAlignmentDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards download progress as a 0–1 fraction.
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

    // File move is handled by the async continuation; nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
