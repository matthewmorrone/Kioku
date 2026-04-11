// OnDeviceLyricAligner.swift
// Drives the on-device forced-alignment pipeline:
//   1. Ensure a GGML Whisper model is present, downloading one automatically if needed.
//   2. Transcribe audio via SwiftWhisper.
//   3. DP-align input lyric lines to transcription segments (LineAligner).
//   4. Emit SRT text (SRTWriter).
//
// Models are downloaded on demand from huggingface.co/ggerganov/whisper.cpp
// and stored in the app support directory via WhisperModelManager.

import Foundation

// Entry point for on-device lyric alignment.
enum OnDeviceLyricAligner {

    // The model downloaded automatically when none is present.
    // "base" (142 MB) gives a good quality/size trade-off for alignment.
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
            print("[OnDeviceAlign] models directory not found at \(dir.path)")
            return nil
        }

        // Prefer models by quality order: medium → small → base → tiny → anything else.
        let preferenceOrder = ["ggml-medium.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"]
        let binFiles = files.filter { $0.hasSuffix(".bin") }
        print("[OnDeviceAlign] found \(binFiles.count) model(s) in \(dir.lastPathComponent): \(binFiles.sorted().joined(separator: ", "))")

        guard binFiles.isEmpty == false else {
            return nil
        }

        for preferred in preferenceOrder {
            if binFiles.contains(preferred) {
                let url = dir.appendingPathComponent(preferred)
                print("[OnDeviceAlign] selected model: \(preferred)")
                return url
            }
        }
        // Fall back to whichever .bin file is present (e.g. a user-named model).
        let fallback = binFiles.sorted().first!
        print("[OnDeviceAlign] selected model (fallback): \(fallback)")
        return dir.appendingPathComponent(fallback)
    }

    // Downloads the default GGML model (base, 142 MB) to the WhisperModels directory.
    // onProgress receives human-readable status strings suitable for display in the UI,
    // called on the main queue as download progresses.
    // Returns the local URL of the downloaded model file.
    static func downloadDefaultModel(onProgress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let model = defaultModel
        let dir = WhisperModelManager.modelsDirectory
        let destination = dir.appendingPathComponent(model.filename)

        // Already present — nothing to do.
        if FileManager.default.fileExists(atPath: destination.path) {
            print("[OnDeviceAlign] model already exists at \(destination.path)")
            return destination
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("[OnDeviceAlign] downloading \(model.filename) from \(model.remoteURL)")

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
        print("[OnDeviceAlign] model saved to \(destination.path)")

        await MainActor.run { onProgress("Model ready.") }
        return destination
    }

    // Transcribes audioURL with the given GGML model, aligns the provided
    // lyric lines to transcription segments using DP, and returns SRT text.
    //
    // lyrics: the full note text (will be split on newlines; blank lines are skipped).
    // modelURL: path to a GGML .bin file — obtain from bestAvailableModelURL() or downloadDefaultModel().
    // onProgress: called on main queue with a 0–1 fraction as Whisper processes audio.
    // onSegment: called on main queue with each decoded segment's text as it arrives.
    static func align(
        audioURL: URL,
        lyrics: String,
        modelURL: URL,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: ((String) -> Void)? = nil
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

        print("[OnDeviceAlign] aligning \(lines.count) line(s) using \(modelURL.lastPathComponent)")
        let provider = SwiftWhisperTranscriptionProvider(modelURL: modelURL)
        let segments = try await provider.transcribe(url: audioURL, onProgress: onProgress, onSegment: onSegment)
        print("[OnDeviceAlign] transcription complete — \(segments.count) segment(s)")

        guard segments.isEmpty == false else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Whisper returned no transcription segments. The audio may be silent or in an unsupported format."]
            )
        }

        let aligned = LineAligner.align(lines: lines, segments: segments)
        print("[OnDeviceAlign] alignment complete — \(aligned.count) aligned line(s)")
        return SRTWriter.write(aligned)
    }
}

// URLSession download delegate that forwards byte-level progress to a closure.
// Kept private to this file; follows the same pattern as WhisperDownloadProgressDelegate
// in WhisperModelManager.swift.
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
