// SingPhonemeModelStore.swift
//
// First-run download + on-disk cache for HubertPhonemeSing.mlmodelc — the same Japanese HuBERT
// phoneme CTC model as [[HubertPhonemeModelStore]], exported with a 4 s input for Sing mode's live
// grading, attached to the Kioku GitHub Release `aligner-sing-v1` (model card and conversion script
// alongside). The download and extraction are [[CoreMLArchiveInstaller]]'s; this file holds the pin.

import Foundation

public enum SingPhonemeModelStore {
    // Storage directory name (ModelStorage), not a hub id.
    public static let modelId = "kioku/HubertPhonemeSing"
    // Release tag + the zip's sha256 pin the bytes every install receives (docs/INVARIANTS.md,
    // pinned model downloads). Republishing = a new tag and both values bumped.
    public static let releaseTag = "aligner-sing-v1"
    public static let sha256 = "cb70cc91fb47b96c1bf3697eded06eed3dbd5aea1ef0e5ed2d024dfe22d94558"
    public static let archiveName = "HubertPhonemeSing.mlmodelc.zip"
    public static let modelDirName = "HubertPhonemeSing.mlmodelc"

    static let spec = CoreMLArchiveSpec(
        modelId: modelId,
        archiveURL: URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(releaseTag)/\(archiveName)")!,
        sha256: sha256,
        modelDirName: modelDirName,
        stageNoun: "Sing model",
        errorNoun: "Sing model",
        errorDomain: "LyricAlignment.Sing",
        errorCodeBase: 60
    )

    // Ensures HubertPhonemeSing.mlmodelc is present, downloading + extracting on first miss.
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        try await CoreMLArchiveInstaller.shared.ensure(spec, onStage: onStage)
    }
}
