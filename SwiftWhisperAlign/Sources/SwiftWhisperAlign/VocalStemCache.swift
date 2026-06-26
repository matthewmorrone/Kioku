// VocalStemCache.swift
//
// On-disk cache for isolated vocal stems. Vocal isolation (the HTDemucs CoreML pass in
// CTCForcedAligner) is the most expensive and memory-hungry stage of alignment — several
// seconds and the jetsam cliff on the A17 — yet the isolated stem is a *pure function* of the
// source audio. Caching it lets every Re-align of unchanged audio skip both the stereo decode
// and the isolation, dropping straight into the (cheap) trim/VAD/align stages.
//
// Format: raw little-endian Float32 mono @ 44.1 kHz (exactly the buffer HTDemucs returns), so
// the round-trip is a byte-for-byte reinterpret — no WAV header to parse, no 16-bit
// quantization. Stored under <Caches>/VocalStems so the OS can reclaim it under storage
// pressure (it's regenerable) and it never inflates iCloud backup or the Files-app view.
//
// Keyed by (filename, byte size): app audio is UUID-named so cross-song collisions are
// impossible, and content-distinct audio essentially always differs in byte size, so a
// re-import that changes the audio misses and regenerates while repeated Re-aligns of
// unchanged audio hit. (mtime is deliberately excluded so the key is reproducible from name
// + size alone — robust to backup/restore and copies that rewrite mtime, and computable
// off-device when seeding the cache.) The `formatVersion` prefix invalidates every entry at
// once if the isolation algorithm ever changes.

import Foundation

public enum VocalStemCache {
    // Sample rate the stem is produced and consumed at. Informational — the stored format is
    // headerless raw Float32, so this isn't encoded in the file; it documents the contract that
    // both the producer (HTDemucs) and the consumer (the aligner's trim/VAD) assume 44.1 kHz.
    private static let sampleRate = 44_100

    // Bump to invalidate all cached stems when the isolation pipeline changes (model, downmix,
    // overlap-add) so an old stem is never silently fed to a new aligner.
    private static let formatVersion = 1

    // Upper bound on what the stem cache may occupy on disk. The cache was previously UNBOUNDED —
    // every aligned song left a ~18 MB .f32 (plus a derived .wav) forever, reaching multiple GB on
    // a well-used device. 500 MB keeps ~25 recent songs' stems for instant Re-align while capping
    // the growth. `Caches/` is OS-purgeable, but iOS only reclaims it under severe pressure, far too
    // late — this enforces the bound ourselves, on launch and after every store.
    public static let maxBytes = 500 * 1024 * 1024

    // <Caches>/VocalStems, created on demand. nil only if the caches directory is unavailable.
    private static func cacheDir() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("VocalStems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Cache-file URL for a source audio file, or nil if the dir is missing. Keyed by CONTENT
    // (version + byte size + a head/tail byte hash), NOT path — so the same audio resolves to one
    // cache entry whether it arrives as the stored attachment (alignment) or a random-named temp copy
    // (transcription). That makes the stem shared + reused across both, so a song is only ever
    // isolated once (HTDemucs is the memory-heavy step we never want to repeat).
    private static func cacheURL(for audioURL: URL) -> URL? {
        guard let dir = cacheDir() else { return nil }
        return dir.appendingPathComponent(fnv1a(contentKey(for: audioURL)) + ".f32")
    }

    // Path-independent content fingerprint: size + FNV-1a over the first and last 256 KB. Cheap
    // (~½ MB read) and specific enough that two different songs won't collide.
    private static func contentKey(for audioURL: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0, let handle = try? FileHandle(forReadingFrom: audioURL) else {
            return "v\(formatVersion)|\(size)"
        }
        defer { try? handle.close() }
        let sample = 262_144
        let head = (try? handle.read(upToCount: sample)) ?? Data()
        var tail = Data()
        if size > UInt64(sample) {
            try? handle.seek(toOffset: size - UInt64(sample))
            tail = (try? handle.read(upToCount: sample)) ?? Data()
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in head { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        for byte in tail { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        return "v\(formatVersion)|\(size)|\(String(format: "%016llx", hash))"
    }

    // Stable, path-independent identity for this audio — the same hex token the stem cache filename
    // is built from. Lets a SIBLING cache (e.g. the resumable anchor-transcript cache) key off the
    // exact same audio identity, so its entry is shared across attachment vs. temp-copy paths too.
    public static func identityKey(for audioURL: URL) -> String { fnv1a(contentKey(for: audioURL)) }

    // [DEBUG] Reports the computed cache filename, the source byte size, and whether a cache file
    // is present — so the harness can read the exact key off the breadcrumb and seed it precisely
    // instead of reverse-engineering the hash off-device (where any mismatch is invisible).
    static func debugKeyInfo(for audioURL: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard let url = cacheURL(for: audioURL) else { return "key=<no-dir> size=\(size)" }
        let exists = FileManager.default.fileExists(atPath: url.path)
        return "key=\(url.lastPathComponent) size=\(size) exists=\(exists)"
    }

    // Deterministic 64-bit FNV-1a, hex-encoded — a stable, fixed-length, collision-resistant
    // cache filename. (Swift's Hashable `hashValue` is per-launch randomized and unusable on disk.)
    private static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // Loads the cached mono stem for `audioURL`, or nil on miss / unreadable / malformed. The
    // file is raw little-endian Float32; decoding is a straight reinterpret of the bytes (the
    // cache is written and read on the same little-endian device).
    static func load(for audioURL: URL) -> [Float]? {
        guard let url = cacheURL(for: audioURL),
              let data = try? Data(contentsOf: url),
              data.isEmpty == false,
              data.count % MemoryLayout<Float>.stride == 0 else { return nil }
        // Refresh mtime on a hit so the LRU budget treats a re-aligned song as recently USED, not
        // stale — a frequently re-aligned old song then survives eviction over genuinely cold ones.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let count = data.count / MemoryLayout<Float>.stride
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }

    // Stores the mono stem for `audioURL` as raw little-endian Float32. Best-effort: a write
    // failure (e.g. low disk, or the OS having reclaimed the dir) just means the next align
    // re-isolates. Skips empty input so a failed isolation isn't cached as a valid result.
    static func store(_ samples: [Float], for audioURL: URL) {
        guard samples.isEmpty == false, let url = cacheURL(for: audioURL) else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url, options: .atomic)
        // Drop any stale playable WAV derived from a previous stem at this key, so the next
        // "listen to stem" regenerates it from the fresh isolation.
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("wav"))
        // Keep the cache within budget — this store may have pushed it over.
        enforceBudget()
    }

    // Evicts least-recently-USED entries until the VocalStems dir is at or under `maxBytes`. LRU is
    // by file modificationDate, which `load()` refreshes on a hit, so a hot song outlives cold ones.
    // Counts every file in the dir — both the .f32 stems and any derived .wav (a .wav, being purely
    // regenerable, naturally evicts before its .f32 since it isn't mtime-touched on stem reuse).
    // Best-effort and cheap (one directory scan); call on launch to reclaim pre-existing overflow
    // (e.g. the multi-GB cache an older build accumulated) and after every store.
    public static func enforceBudget(maxBytes: Int = VocalStemCache.maxBytes) {
        guard let dir = cacheDir() else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for url in items {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            files.append((url, size, v.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return }
        for f in files.sorted(by: { $0.mtime < $1.mtime }) {   // oldest first
            if total <= maxBytes { break }
            if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
        }
    }

    // Whether a cached stem exists for `audioURL` (cheap existence check, no decode) — drives
    // whether the UI offers the "listen to the isolated vocals" affordance.
    public static func hasStem(for audioURL: URL) -> Bool {
        guard let url = cacheURL(for: audioURL) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // Returns a playable 16-bit PCM WAV of the cached stem for `audioURL`, generating it from the
    // raw f32 on first call and caching the .wav alongside (same dir, same key). nil if no stem is
    // cached yet (the song hasn't been aligned). Lets the UI play back exactly what the aligner
    // hears — the isolated vocals — without re-running isolation.
    public static func stemWAVURL(for audioURL: URL) -> URL? {
        guard let f32URL = cacheURL(for: audioURL) else { return nil }
        let wavURL = f32URL.deletingPathExtension().appendingPathExtension("wav")
        if FileManager.default.fileExists(atPath: wavURL.path) { return wavURL }
        guard let samples = load(for: audioURL) else { return nil }
        return writeWAV16(samples, to: wavURL) ? wavURL : nil
    }

    // Writes mono float samples as a 16-bit PCM WAV (canonical 44-byte little-endian header +
    // samples). Hand-rolled so the cache needn't import AVFoundation; the stem is always mono @
    // 44.1 kHz. Returns false on write failure.
    private static func writeWAV16(_ samples: [Float], to url: URL) -> Bool {
        let dataBytes = samples.count * 2
        let byteRate = sampleRate * 2
        var header = Data()
        let appendStr: (String) -> Void = { header.append(contentsOf: Array($0.utf8)) }
        let appendU32: (UInt32) -> Void = { v in
            header.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                       UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        let appendU16: (UInt16) -> Void = { v in
            header.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
        }
        appendStr("RIFF"); appendU32(UInt32(36 + dataBytes)); appendStr("WAVE")
        appendStr("fmt "); appendU32(16); appendU16(1); appendU16(1)
        appendU32(UInt32(sampleRate)); appendU32(UInt32(byteRate)); appendU16(2); appendU16(16)
        appendStr("data"); appendU32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            pcm[i] = Int16((max(-1.0, min(1.0, samples[i])) * 32767).rounded())
        }
        var out = header
        pcm.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        return (try? out.write(to: url, options: .atomic)) != nil
    }
}
