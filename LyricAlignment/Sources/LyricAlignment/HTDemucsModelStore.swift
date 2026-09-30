// HTDemucsModelStore.swift
// First-run download + on-disk cache for HTDemucsSpec.mlmodelc — the CoreML vocal isolator
// CTCForcedAligner runs before forced alignment. The model is 269 MB uncompressed, hosted
// as a single .zip on HuggingFace. The download and extraction are [[CoreMLArchiveInstaller]]'s;
// this file holds the hub coordinates.
//
// Cache lives under [[ModelStorage]]'s Application Support tree (same purge-resistant,
// off-iCloud-backup placement as the aligner weights), so a future reinstall is the only event
// that wipes it — and reinstall self-heals on the next align run.

import Foundation

public enum HTDemucsModelStore {
    // HF Hub coordinates. `revision` is pinned to the commit SHA of the upload (NOT `main`)
    // so a future hub-side edit or tag move can't silently swap the model bytes shipping with
    // installs (docs/INVARIANTS.md, pinned model downloads). Bump this any
    // time the model is republished.
    public static let modelId = "matthewmorrone/HTDemucs-CoreML"
    public static let revision = "1814775e602778cc093cb23138d773645166d724"
    public static let archiveName = "HTDemucsSpec.mlmodelc.zip"
    public static let modelDirName = "HTDemucsSpec.mlmodelc"

    static let spec = CoreMLArchiveSpec(
        modelId: modelId,
        archiveURL: URL(string: "https://huggingface.co/\(modelId)/resolve/\(revision)/\(archiveName)")!,
        sha256: nil,
        modelDirName: modelDirName,
        stageNoun: "isolator",
        errorNoun: "Vocal isolator",
        errorDomain: "LyricAlignment.HTDemucs",
        errorCodeBase: 30
    )

    // Final on-disk location of the extracted .mlmodelc bundle.
    public static func modelURL() throws -> URL {
        try CoreMLArchiveInstaller.modelURL(for: spec)
    }

    // Ensures HTDemucsSpec.mlmodelc is present at the model URL, downloading + extracting
    // the archive on first miss. `onStage` reports human-readable phase text the alignment HUD
    // surfaces ("Downloading isolator… 42%", "Extracting isolator…").
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        try await CoreMLArchiveInstaller.shared.ensure(spec, onStage: onStage)
    }
}
