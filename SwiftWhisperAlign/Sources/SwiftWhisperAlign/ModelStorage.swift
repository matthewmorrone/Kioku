// ModelStorage.swift
//
// Resolves the on-disk cache directory for downloaded speech models (ASR weights, the
// CTC forced-aligner). The Qwen3 SDK defaults to ~/Library/Caches/qwen3-speech, but iOS
// purges Caches under storage pressure and the HuggingFace downloader cannot resume a
// half-transferred file — so a mid-download purge strands the next launch on "downloading
// alignment model 83%". Application Support is not purgeable; the directory is also
// flagged out of iCloud backup so a ~600 MB re-downloadable blob doesn't burn the user's
// iCloud quota.

import Foundation

public enum ModelStorage {
    // Model IDs are pinned here (rather than relying on the SDK's `fromPretrained` defaults)
    // so the cache directory and the requested weights cannot drift apart silently.
    public static let asrModelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    public static let forcedAlignerModelId = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"

    // Returns a per-model subdirectory under Application Support, creating it on demand.
    // Slashes in the model id ("aufklarer/Qwen3-…") become nested path components, mirroring
    // the HF Hub on-disk layout — two different model ids cannot clobber each other.
    //
    // The `models/` segment is REQUIRED by speech-swift's HuggingFaceDownloader: makeHubApi()
    // strips the literal `/models/<org>/<model>` suffix from the cacheDir to derive its
    // `downloadBase`. Without `models/` here the suffix check fails, the downloader silently
    // falls back to `<App Caches>/<parent-dir-name>/…` (purgeable!), and the post-download
    // safetensors check looks at our cacheDir and finds nothing — "No safetensors files found".
    public static func directory(for modelId: String) throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "SwiftWhisperAlign.ModelStorage",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no Application Support directory available"]
            )
        }
        var dir = base.appendingPathComponent("SpeechModels", isDirectory: true)
                      .appendingPathComponent("models", isDirectory: true)
                      .appendingPathComponent(modelId, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Models are large and re-downloadable — keep them off iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }
}
