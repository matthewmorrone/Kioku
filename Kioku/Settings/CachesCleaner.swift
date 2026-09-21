// CachesCleaner.swift
//
// Measures and clears the app's disposable on-disk state: everything under Library/Caches
// (CoreML's compiled-model bundles, the Hub downloader's content-addressed staging copies of
// every model, per-piece transcript checkpoints), tmp/ (URLSession download temp files
// that the Hub client leaks — one full-size CFNetworkDownload_*.tmp per model file), and the
// cached isolated vocal stems — a cache by nature that lives in Application Support only so
// iOS can't purge it (see VocalStemCache's header). Used by the Settings "Clear Caches"
// button, and by the launch-time sweep for the subset that is never worth keeping. The
// downloaded model weights, also in Application Support, are intentionally NOT touched:
// those are slow to re-download.

import Foundation
import SwiftWhisperAlign

// Nonisolated so Settings can call from a detached background Task without hopping back to
// MainActor — the work is pure FileManager I/O and returns plain Int.
nonisolated enum CachesCleaner {
    // Sum of byte sizes of every regular file under the cache roots, recursively.
    static func measure() -> Int {
        roots().reduce(0) { $0 + totalRegularFileBytes(at: $1) }
    }

    // Deletes every top-level entry under the cache roots (whole subtrees). Returns
    // the freed byte count, computed from a pre-scan so the number is accurate even if some
    // entries fail to delete. Safe to call off the main thread — does no UI work.
    @discardableResult
    static func clearAll() -> Int {
        var freed = 0
        for root in roots() {
            let before = totalRegularFileBytes(at: root)
            removeContents(of: root)
            freed += max(0, before - totalRegularFileBytes(at: root))
        }
        return freed
    }

    // Launch-time sweep of state that is pure dead weight once the process has restarted:
    //   - tmp/: URLSession download temp files (the Hub client copies them and never deletes
    //     the original; nothing is in flight at launch, so everything here is stale)
    //   - Library/Caches/huggingface + aufklarer: the Hub downloader's staging copies. The
    //     materialized weights live in Application Support and the downloader's skip check
    //     reads that copy (+ its .metadata sidecar), so the staging copy is never consulted
    //     again — it's a byte-for-byte duplicate of every model
    //   - Library/Caches/VocalStems: the stem cache's pre-Application-Support location
    //   - CoreML's compiled-model bundles, but only when the app build changed since the last
    //     launch (see sweepCompiledBundlesIfBuildChanged). Returns freed bytes.
    @discardableResult
    static func sweepStaleDownloads() -> Int {
        let fm = FileManager.default
        var targets: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets += ["huggingface", "aufklarer", "VocalStems"].map {
                caches.appendingPathComponent($0, isDirectory: true)
            }
        }
        var freed = 0
        for url in targets where fm.fileExists(atPath: url.path) {
            freed += totalRegularFileBytes(at: url)
            try? fm.removeItem(at: url)
        }
        let tmp = fm.temporaryDirectory
        freed += totalRegularFileBytes(at: tmp)
        removeContents(of: tmp)
        freed += sweepCompiledBundlesIfBuildChanged()
        return freed
    }

    // CoreML's compiled-model bundles are keyed per app build, so every install leaves the
    // previous build's bundles behind (a day of development builds cost ~13 GB). On the first
    // launch of a new build the compiled cache is dropped wholesale: this build has to compile
    // its own bundles anyway, so nothing that would be reused is lost. Returns freed bytes.
    private static func sweepCompiledBundlesIfBuildChanged() -> Int {
        let fm = FileManager.default
        let key = "kioku.caches.lastBuildFingerprint"
        let fingerprint = Bundle.main.executableURL
            .flatMap { try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .map { String($0.timeIntervalSince1970) } ?? Bundle.main.bundleIdentifier ?? ""
        guard UserDefaults.standard.string(forKey: key) != fingerprint else { return 0 }
        UserDefaults.standard.set(fingerprint, forKey: key)
        var freed = 0
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first, let bundleId = Bundle.main.bundleIdentifier {
            // iOS: Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache holds the compiled bundles.
            let url = caches
                .appendingPathComponent(bundleId, isDirectory: true)
                .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                freed += totalRegularFileBytes(at: url)
                try? fm.removeItem(at: url)
            }
        }
        return freed
    }

    // The roots "Clear Caches" covers — single source for both measure and clear, so they can
    // never drift to looking at different paths.
    private static func roots() -> [URL] {
        var urls: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            urls.append(caches)
        }
        urls.append(FileManager.default.temporaryDirectory)
        if let stems = VocalStemCache.directoryForStorageManagement() {
            urls.append(stems)
        }
        return urls
    }

    // Removes every top-level entry under `root`, leaving the directory itself in place.
    private static func removeContents(of root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }

    // Recursive byte sum of regular files under `root`. Ignores symlinks and directory
    // entries themselves (their bytes are dwarfed by content).
    private static func totalRegularFileBytes(at root: URL) -> Int {
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
}
