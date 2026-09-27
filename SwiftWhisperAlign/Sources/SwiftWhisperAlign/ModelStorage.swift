// ModelStorage.swift
//
// Resolves the on-disk directory for downloaded speech models (the MMS aligner, the HTDemucs
// isolator). iOS purges Caches under storage pressure and a half-transferred model cannot
// resume — so a mid-download purge strands the next launch on "downloading alignment model
// 83%". Application Support is not purgeable; the directory is also
// flagged out of iCloud backup so a ~600 MB re-downloadable blob doesn't burn the user's
// iCloud quota.

import Foundation

public enum ModelStorage {
    // Qwen3-ASR builds earlier app versions downloaded (MLX weights, then the CoreML export).
    // Nothing loads them; the storage-management screen still measures and reclaims them
    // ([[DownloadedModelsStore]]).
    public static let retiredASRModelIds = [
        "aufklarer/Qwen3-ASR-CoreML",
        "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
    ]
    // Qwen3 forced-aligner builds earlier app versions downloaded. Nothing loads them (the
    // aligner is now MMS via [[MMSModelStore]]), but the storage-management screen still
    // measures and reclaims them ([[DownloadedModelsStore]]).
    public static let retiredForcedAlignerModelIds = [
        "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
        "aufklarer/Qwen3-ForcedAligner-0.6B-8bit",
        "aufklarer/Qwen3-ForcedAligner-0.6B-bf16",
    ]
    // MLX HTDemucs-FT weights earlier app versions downloaded. Nothing reads them (the isolator
    // is the CoreML build in [[HTDemucsModelStore]]); kept so storage management can reclaim them.
    public static let htDemucsFTModelId = "aufklarer/HTDemucs-FT-MLX"

    // Returns a per-model subdirectory under Application Support, creating it on demand.
    // Slashes in the model id ("aufklarer/Qwen3-…") become nested path components, mirroring
    // the HF Hub on-disk layout — two different model ids cannot clobber each other.
    //
    // The `models/` segment is part of the path every existing download already lives under;
    // changing it would orphan those files.
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
