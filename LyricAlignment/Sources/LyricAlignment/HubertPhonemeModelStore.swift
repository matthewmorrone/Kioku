// HubertPhonemeModelStore.swift
//
// First-run download + on-disk cache for HubertPhonemeAligner.mlmodelc — a Japanese HuBERT-base
// phoneme CTC model (prj-beatrice/japanese-hubert-base-phoneme-ctc-v4, Apache-2.0), exported to
// CoreML (fp16, norms fp32) and attached to the Kioku GitHub Release `aligner-hubert-v1` (model card
// and conversion script alongside). The download and extraction are [[CoreMLArchiveInstaller]]'s;
// this file holds the pin.

import Foundation

public enum HubertPhonemeModelStore {
    // Storage directory name (ModelStorage), not a hub id.
    public static let modelId = "kioku/HubertPhonemeAligner"
    // Release tag + the zip's sha256 pin the bytes every install receives (docs/INVARIANTS.md,
    // pinned model downloads): a release asset can be re-uploaded under the same tag, so the hash
    // is what's actually immutable. Republishing = a new tag and both values bumped.
    public static let releaseTag = "aligner-hubert-v1"
    public static let sha256 = "a159a58fafb294ba44894769cbf2f80c1e141a2cf7dc081c92228498f2b0d42a"
    public static let archiveName = "HubertPhonemeAligner.mlmodelc.zip"
    public static let modelDirName = "HubertPhonemeAligner.mlmodelc"

    static let spec = CoreMLArchiveSpec(
        modelId: modelId,
        archiveURL: URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(releaseTag)/\(archiveName)")!,
        sha256: sha256,
        modelDirName: modelDirName,
        stageNoun: "aligner",
        errorNoun: "Aligner",
        errorDomain: "LyricAlignment.Aligner",
        errorCodeBase: 45
    )

    // Final on-disk location of the extracted .mlmodelc bundle.
    public static func modelURL() throws -> URL {
        try CoreMLArchiveInstaller.modelURL(for: spec)
    }

    // Ensures HubertPhonemeAligner.mlmodelc is present, downloading + extracting on first miss.
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        try await CoreMLArchiveInstaller.shared.ensure(spec, onStage: onStage)
    }
}
