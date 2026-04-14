// OnDeviceLyricAligner.swift
// Drives the on-device forced-alignment pipeline:
//   1. Ensure a GGML Whisper model + Core ML encoder are present,
//      downloading them automatically if needed.
//   2. Force-align input lyric lines to audio using whisper.cpp's
//      logits_filter_callback (via WhisperKitAlign).
//   3. Emit SRT text (SRTWriter).
//
// Models are downloaded from huggingface.co/ggerganov/whisper.cpp and stored
// in the app support directory managed by WhisperModelManager.

import Foundation
import WhisperKitAlign

// Entry point for on-device lyric alignment.
enum OnDeviceLyricAligner {

    // The model downloaded automatically when none is present.
    // "tiny" (75 MB) is used as the default because alignment already has the ground truth
    // text — the model only needs to produce rough timestamps, not perfect transcription.
    // Users can download larger models from Settings → Whisper Models for better accuracy.
    private static let defaultModel = WhisperDownloadableModel(
        id: "tiny",
        displayName: "Tiny",
        filename: "ggml-tiny.bin",
        parameters: "39M",
        sizeMB: 75
    )

    // Returns the best available downloaded GGML model URL, preferring
    // higher-quality models. Returns nil if no model has been downloaded yet.
    static func bestAvailableModelURL() -> URL? {
        let dir = WhisperModelManager.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            print("[OnDeviceAlign] models directory not found at \(dir.path)")
            return nil
        }

        let preferenceOrder = ["ggml-medium.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"]
        let binFiles = files.filter { $0.hasSuffix(".bin") }
        print("[OnDeviceAlign] found \(binFiles.count) model(s): \(binFiles.sorted().joined(separator: ", "))")
        guard binFiles.isEmpty == false else { return nil }

        for preferred in preferenceOrder {
            if binFiles.contains(preferred) {
                print("[OnDeviceAlign] selected model: \(preferred)")
                return dir.appendingPathComponent(preferred)
            }
        }
        let fallback = binFiles.sorted().first!
        print("[OnDeviceAlign] selected model (fallback): \(fallback)")
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
            print("[OnDeviceAlign] GGML model saved to \(destination.path)")
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
            print("[OnDeviceAlign] Core ML encoder already present: \(encoderDir.lastPathComponent)")
            return
        }

        // Derive the zip filename, e.g. "ggml-base-encoder.mlmodelc.zip"
        let zipName = encoderDir.lastPathComponent + ".zip"
        guard let zipURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(zipName)") else {
            return
        }

        print("[OnDeviceAlign] downloading Core ML encoder: \(zipName)")
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
                print("[OnDeviceAlign] HTTP \(status) for \(zipName); will use CPU fallback")
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
                print("[OnDeviceAlign] Core ML encoder ready: \(encoderDir.path)")
            } else {
                print("[OnDeviceAlign] extraction succeeded but encoder dir not found — zip structure may differ")
            }
        } catch {
            print("[OnDeviceAlign] Core ML encoder download/extraction failed: \(error); will use CPU fallback")
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
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: (([WhisperKitAlign.AlignedLine]) -> Void)? = nil
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

        print("[OnDeviceAlign] force-aligning \(lines.count) line(s) using \(modelURL.lastPathComponent)")

        let aligner = ForcedAligner(modelURL: modelURL)
        let input = AlignmentInput(audioURL: audioURL, lines: lines)
        let srt = try await aligner.alignToSRT(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onSegment: onSegment
        )

        print("[OnDeviceAlign] alignment complete")
        return srt
    }
}

// URLSession download delegate that forwards byte-level progress to a closure.
private final class WhisperAlignmentDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
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
