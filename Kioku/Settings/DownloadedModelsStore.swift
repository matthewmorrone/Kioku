// DownloadedModelsStore.swift
//
// Measures and deletes the on-device speech models — plus the isolated vocal stems they
// produce — that live OUTSIDE Library/Caches (see CachesCleaner's header for why): the Qwen3
// ASR + forced-aligner weights and the HTDemucs vocal isolator under Application
// Support/SpeechModels ([[ModelStorage]]), and cached stems under Application
// Support/VocalStems ([[VocalStemCache]]) — none of which iOS will purge under storage
// pressure. "Clear Caches" deliberately doesn't touch these — this is the counterpart for a
// user who explicitly wants the space back, at the cost of a re-download (models) or
// re-isolation (stems) next time the corresponding feature runs.

import Foundation
import SwiftWhisperAlign

nonisolated enum DownloadedModelsStore {
    // On-disk size of the downloaded Qwen3-ASR weights, or 0 if not yet downloaded. Sums both
    // builds: the CoreML export StemTranscriber actually runs, and the MLX weights — orphaned
    // now that nothing loads them, but still worth reclaiming for anyone who downloaded them
    // under an older app version.
    static func qwenASRSizeBytes() -> Int {
        sizeBytes(at: try? ModelStorage.directory(for: ModelStorage.asrCoreMLModelId))
            + sizeBytes(at: try? ModelStorage.directory(for: ModelStorage.asrModelId))
    }

    // On-disk size of the forced-aligner weights, or 0 if not yet downloaded. Sums the MMS
    // CoreML model the app loads plus any retired Qwen3 aligner build an older app version
    // downloaded — orphaned, but still worth reclaiming.
    static func qwenForcedAlignerSizeBytes() -> Int {
        forcedAlignerModelIds.reduce(0) { $0 + sizeBytes(at: try? ModelStorage.directory(for: $1)) }
    }

    private static var forcedAlignerModelIds: [String] {
        [MMSModelStore.modelId] + ModelStorage.retiredForcedAlignerModelIds
    }

    // Sums every on-disk copy of the vocal isolator a user could have, depending on which app
    // version first downloaded it: the CoreML .mlmodelc (HTDemucsModelStore, its own legacy
    // Documents sideload) — the only isolator this app now runs — and the MLX HTDemucs-FT
    // weights, orphaned now that CTCForcedAligner's isolation call site dropped that path but
    // still worth reclaiming for anyone who downloaded them under an older app version.
    static func htDemucsSizeBytes() -> Int {
        sizeBytes(at: try? ModelStorage.directory(for: HTDemucsModelStore.modelId))
            + sizeBytes(at: legacyHTDemucsURL())
            + sizeBytes(at: try? ModelStorage.directory(for: ModelStorage.htDemucsFTModelId))
    }

    // On-disk size of the cached isolated vocal stems (VocalStemCache), or 0 if empty. Listed as
    // its own row under Caches; "Clear Caches" covers it (CachesCleaner's roots include it).
    static func vocalStemsSizeBytes() -> Int {
        sizeBytes(at: VocalStemCache.directoryForStorageManagement())
    }

    // Deletes every cached isolated vocal stem. No-op if nothing is cached.
    static func deleteVocalStems() {
        VocalStemCache.deleteAll()
    }

    // Deletes every on-disk copy of the Qwen3-ASR weights (see qwenASRSizeBytes). No-op if
    // nothing is downloaded.
    static func deleteQwenASR() {
        removeContents(of: try? ModelStorage.directory(for: ModelStorage.asrCoreMLModelId))
        removeContents(of: try? ModelStorage.directory(for: ModelStorage.asrModelId))
    }

    // Deletes every on-disk copy of the forced-aligner weights (see
    // qwenForcedAlignerSizeBytes). No-op if nothing is downloaded.
    static func deleteQwenForcedAligner() {
        for id in forcedAlignerModelIds {
            removeContents(of: try? ModelStorage.directory(for: id))
        }
    }

    // Deletes every on-disk copy of the HTDemucs vocal isolator (see htDemucsSizeBytes).
    static func deleteHTDemucs() {
        removeContents(of: try? ModelStorage.directory(for: HTDemucsModelStore.modelId))
        if let legacyURL = legacyHTDemucsURL() {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        removeContents(of: try? ModelStorage.directory(for: ModelStorage.htDemucsFTModelId))
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

    // One reclaimable item under Library/Caches or tmp, shown in the Storage list so what
    // "Clear Caches" removes is visible before and after. Top-level Caches entries are listed one
    // per row; tmp is one row.
    struct CacheEntry: Identifiable {
        let id: String
        let label: String
        let url: URL
        let bytes: Int
        let isTmp: Bool
    }

    // Every non-empty top-level entry of Library/Caches plus tmp, with human labels for the
    // well-known ones (CoreML's compiled-model bundles, the Hub downloader's staging copies).
    static func cacheEntries() -> [CacheEntry] {
        let fm = FileManager.default
        var out: [CacheEntry] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let names = try? fm.contentsOfDirectory(atPath: caches.path) {
            for name in names.sorted() {
                let url = caches.appendingPathComponent(name)
                let bytes = sizeBytes(at: url)
                if bytes >= 1_000_000 { out.append(CacheEntry(id: url.path, label: cacheLabel(for: name), url: url, bytes: bytes, isTmp: false)) }
            }
        }
        let tmp = fm.temporaryDirectory
        let tmpBytes = sizeBytes(at: tmp)
        if tmpBytes > 0 { out.append(CacheEntry(id: tmp.path, label: "Temporary Downloads", url: tmp, bytes: tmpBytes, isTmp: true)) }
        return out
    }

    // Removes one cache entry (tmp keeps its directory, only its contents go).
    static func delete(_ entry: CacheEntry) {
        if entry.isTmp { removeContents(of: entry.url) } else { try? FileManager.default.removeItem(at: entry.url) }
    }

    // Friendly name for a Caches folder; unknown folders show their own name. iOS keeps CoreML's
    // compiled bundles (com.apple.e5rt.e5bundlecache) and the Metal shader caches inside a folder
    // named after the app's bundle identifier.
    private static func cacheLabel(for name: String) -> String {
        let lower = name.lowercased()
        if name == Bundle.main.bundleIdentifier { return "Compiled Model Bundles" }
        if lower.contains("e5rt") || lower.contains("coreml") || lower.contains("mlmodelc") { return "Compiled Model Bundles" }
        if lower == "com.apple.dyld" { return "Launch Cache" }
        if lower == "huggingface" || lower == "aufklarer" { return "Model Download Staging (\(name))" }
        if lower == "vocalstems" { return "Old Isolated Vocals" }
        return name
    }
}
