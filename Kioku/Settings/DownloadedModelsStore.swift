// DownloadedModelsStore.swift
//
// Measures and deletes the on-device speech models that live OUTSIDE Library/Caches (see
// CachesCleaner's header for why): the Qwen3 ASR + forced-aligner weights and the HTDemucs
// vocal isolator, all rooted under Application Support/SpeechModels ([[ModelStorage]]) so iOS
// won't purge them under storage pressure. "Clear Caches" deliberately doesn't touch these —
// this is the counterpart for a user who explicitly wants the space back, at the cost of a
// re-download next time the corresponding feature (alignment, bulk-import transcription) runs.

import Foundation
import SwiftWhisperAlign

nonisolated enum DownloadedModelsStore {
    // On-disk size of the downloaded Qwen3-ASR weights, or 0 if not yet downloaded.
    static func qwenASRSizeBytes() -> Int {
        sizeBytes(at: try? ModelStorage.directory(for: ModelStorage.asrModelId))
    }

    // On-disk size of the downloaded Qwen3-ForcedAligner weights, or 0 if not yet downloaded.
    static func qwenForcedAlignerSizeBytes() -> Int {
        sizeBytes(at: try? ModelStorage.directory(for: ModelStorage.forcedAlignerModelId))
    }

    // Sums the primary Application Support copy and the legacy Documents sideload (see
    // HTDemucsModelStore's diagnostic-fallback comment) — a user could have either, or both,
    // on disk depending on which app version first downloaded it.
    static func htDemucsSizeBytes() -> Int {
        sizeBytes(at: try? ModelStorage.directory(for: HTDemucsModelStore.modelId)) + sizeBytes(at: legacyHTDemucsURL())
    }

    // Deletes the downloaded Qwen3-ASR weights. No-op if nothing is downloaded.
    static func deleteQwenASR() {
        removeContents(of: try? ModelStorage.directory(for: ModelStorage.asrModelId))
    }

    // Deletes the downloaded Qwen3-ForcedAligner weights. No-op if nothing is downloaded.
    static func deleteQwenForcedAligner() {
        removeContents(of: try? ModelStorage.directory(for: ModelStorage.forcedAlignerModelId))
    }

    // Deletes the downloaded HTDemucs vocal isolator — both the primary Application Support
    // copy and the legacy Documents sideload, if either is present.
    static func deleteHTDemucs() {
        removeContents(of: try? ModelStorage.directory(for: HTDemucsModelStore.modelId))
        if let legacyURL = legacyHTDemucsURL() {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // The legacy Documents/HTDemucsSpec.mlmodelc sideload path (see HTDemucsModelStore's
    // diagnostic-fallback comment) — a second possible on-disk copy outside ModelStorage.
    private static func legacyHTDemucsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HTDemucsSpec.mlmodelc", isDirectory: true)
    }

    // Recursive byte sum of regular files under `root`, or 0 if unreadable/nil — mirrors
    // CachesCleaner.totalRegularFileBytes so the two size readouts stay comparable. Not private:
    // the public API above always resolves real Application Support paths (downloaded models,
    // if any, live there), so tests exercise this pure path-in/byte-count-out logic directly
    // against disposable temp directories instead of touching real on-device model state.
    static func sizeBytes(at root: URL?) -> Int {
        guard let root else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            total += v.fileSize ?? 0
        }
        return total
    }

    // Removes every top-level entry under `root` (the model's contents) but leaves the empty
    // directory in place — ModelStorage.directory(for:) always recreates it on next access
    // anyway, and an empty directory costs nothing. Not private: see sizeBytes' comment on why
    // tests target this directly instead of the real-path public API.
    static func removeContents(of root: URL?) {
        guard let root else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }
}
