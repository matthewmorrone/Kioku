// MMSModelStore.swift
//
// First-run download + on-disk cache for MMSForcedAligner.mlmodelc — Meta's MMS forced
// aligner (wav2vec2 + CTC over a romanized alphabet), exported to CoreML at fp16. The download
// and extraction are [[CoreMLArchiveInstaller]]'s; this file holds the hub coordinates and the
// sideload override.

import Foundation

public enum MMSModelStore {
    public static let modelId = "matthewmorrone/MMS-ForcedAligner-CoreML"
    // Pinned to the upload's commit SHA (NOT `main`) so a future hub-side edit or force-push can't
    // silently swap the bytes every install receives (docs/INVARIANTS.md, pinned model downloads).
    // Bump this any time the model is republished.
    public static let revision = "cb801ee8e71955c779f2f3601ef14dde79a9f297"
    public static let archiveName = "MMSForcedAligner.mlmodelc.zip"
    public static let modelDirName = "MMSForcedAligner.mlmodelc"

    static let spec = CoreMLArchiveSpec(
        modelId: modelId,
        revision: revision,
        archiveName: archiveName,
        modelDirName: modelDirName,
        stageNoun: "aligner",
        errorNoun: "Aligner",
        errorDomain: "LyricAlignment.MMS",
        errorCodeBase: 40
    )

    // Final on-disk location of the extracted .mlmodelc bundle.
    public static func modelURL() throws -> URL {
        try CoreMLArchiveInstaller.modelURL(for: spec)
    }

    // Ensures MMSForcedAligner.mlmodelc is present, downloading + extracting on first miss.
    // Debug builds only: a sideloaded copy under <App Documents>/MMSForcedAligner.mlmodelc wins
    // when present, so a locally converted model can be tried on the device without republishing.
    // Delete it once the experiment is over, or the device never exercises the real download.
    public static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        #if DEBUG
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let sideloaded = docs.appendingPathComponent(modelDirName, isDirectory: true)
            if FileManager.default.fileExists(atPath: sideloaded.appendingPathComponent("model.mil").path) {
                return sideloaded
            }
        }
        #endif
        return try await CoreMLArchiveInstaller.shared.ensure(spec, onStage: onStage)
    }
}
