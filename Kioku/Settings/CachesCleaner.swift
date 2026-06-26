// CachesCleaner.swift
//
// Measures and clears everything under the app's Library/Caches directory. Used by the
// Settings "Clear Caches" button to give the user manual control over the on-disk caches
// the app accumulates (isolated vocal stems, per-piece transcript checkpoints, the
// legacy purgeable model dir from before the Application Support move). The Application
// Support tree — where the downloaded ASR + aligner model weights now live — is OUTSIDE
// Caches and is intentionally NOT touched: those are slow to re-download and the whole
// point of moving them was to keep them safe from eviction.

import Foundation

// Nonisolated so Settings can call from a detached background Task without hopping back to
// MainActor — the work is pure FileManager I/O and returns plain Int.
nonisolated enum CachesCleaner {
    // Sum of byte sizes of every regular file under Library/Caches/, recursively. Returns 0
    // if the directory can't be read.
    static func measure() -> Int {
        guard let root = cachesRoot() else { return 0 }
        return totalRegularFileBytes(at: root)
    }

    // Deletes every top-level entry under Library/Caches/ (the whole subtree, recursively).
    // Returns the freed byte count, computed from a pre-scan so the number is accurate even
    // if some entries fail to delete. Safe to call off the main thread — does no UI work.
    @discardableResult
    static func clearAll() -> Int {
        guard let root = cachesRoot() else { return 0 }
        let before = totalRegularFileBytes(at: root)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else {
            return 0
        }
        for url in entries {
            try? fm.removeItem(at: url)
        }
        let after = totalRegularFileBytes(at: root)
        return max(0, before - after)
    }

    // The app's Library/Caches root — single source for both measure and clear, so they
    // can never drift to looking at different paths.
    private static func cachesRoot() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
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
