// VocalStemCache.swift
//
// On-disk cache for isolated vocal stems. Vocal isolation (HTDemucs-FT in CTCForcedAligner) is
// the most expensive stage of alignment — minutes, not seconds — yet the isolated stem is a
// *pure function* of the source audio. Caching it lets every Re-align of unchanged audio skip
// both the stereo decode and the isolation, dropping straight into the (cheap) trim/VAD/align
// stages.
//
// Format: 16-bit Apple Lossless mono @ 44.1 kHz in an .m4a. A quarter the size of the raw Float32
// buffer HTDemucs returns (a 3-minute stem: 30.8 MB → 7.6 MB), lossless below the 16-bit
// quantization, and directly playable — the "listen to the isolated vocals" affordance plays the
// cache file itself. Samples beyond ±1.0 clip. Stored under Application Support/VocalStems (NOT Caches, despite being
// regenerable): a Caches-resident stem was observed getting wiped across ordinary dev-reinstall
// cycles on a nearly-empty 512 GB device — nowhere near genuine storage pressure — so Caches'
// "OS may purge any time" contract was costing a real ~3.5 min HTDemucs-FT re-isolation on
// every rebuild during testing, and would just as well bite a real user's low-storage moment.
// `enforceBudget` (below) is the self-imposed cap that Caches used to give us for free; marked
// excluded from iCloud backup (Application Support IS backed up by default, unlike Caches) so a
// multi-hundred-MB regenerable cache doesn't burn the user's iCloud quota.
//
// Keyed by (filename, byte size): app audio is UUID-named so cross-song collisions are
// impossible, and content-distinct audio essentially always differs in byte size, so a
// re-import that changes the audio misses and regenerates while repeated Re-aligns of
// unchanged audio hit. (mtime is deliberately excluded so the key is reproducible from name
// + size alone — robust to backup/restore and copies that rewrite mtime, and computable
// off-device when seeding the cache.) The `formatVersion` prefix invalidates every entry at
// once if the isolation algorithm ever changes.

import AVFoundation
import Foundation

public enum VocalStemCache {
    // Sample rate the stem is produced, stored and consumed at: both the producer (HTDemucs) and
    // the consumer (the aligner's trim/VAD) assume 44.1 kHz.
    private static let sampleRate = 44_100

    // Frames moved per AVAudioFile read/write, so a whole song never needs a second full-size buffer.
    private static let chunkFrames: AVAudioFrameCount = 1 << 20

    // Bump to invalidate all cached stems when the isolation pipeline changes (model, downmix,
    // overlap-add) so an old stem is never silently fed to a new aligner.
    private static let formatVersion = 1

    // Upper bound on what the stem cache may occupy on disk. A stem is ~2.5 MB per minute of song
    // (~10 MB for four minutes), so 250 MB keeps ~25 recent songs' stems for instant Re-align. This
    // lives in Application Support (not Caches), so the OS won't reclaim it on its own — this bound
    // is the only thing keeping it from growing without limit.
    public static let maxBytes = 250 * 1024 * 1024

    // Application Support/VocalStems, created on demand and excluded from iCloud backup (see the
    // header comment for why this isn't Caches). nil only if Application Support is unavailable.
    private static func cacheDir() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var dir = support.appendingPathComponent("VocalStems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    // Cache-file URL for a source audio file, or nil if the dir is missing. Keyed by CONTENT
    // (version + byte size + a head/tail byte hash), NOT path — so the same audio resolves to one
    // cache entry whether it arrives as the stored attachment (alignment) or a random-named temp copy
    // (transcription). That makes the stem shared + reused across both, so a song is only ever
    // isolated once (HTDemucs is the memory-heavy step we never want to repeat).
    private static func cacheURL(for audioURL: URL) -> URL? {
        guard let dir = cacheDir() else { return nil }
        return dir.appendingPathComponent(fnv1a(contentKey(for: audioURL)) + ".m4a")
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

    // The stem cache's on-disk directory, for Settings' storage-management UI to measure and
    // reclaim — now that it lives in Application Support, "Clear Caches" no longer sweeps it,
    // so this is the only way a user gets that space back short of `deleteAll`.
    public static func directoryForStorageManagement() -> URL? { cacheDir() }

    // Deletes every cached stem. No-op if nothing is cached yet.
    public static func deleteAll() {
        guard let dir = cacheDir(),
              let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
    }

    // Deletes the cached stem for one song, so its next alignment isolates the vocals afresh.
    // Backs the lyric view's "Re-align from Scratch" action. No-op if nothing is cached.
    public static func delete(for audioURL: URL) {
        guard let url = cacheURL(for: audioURL), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[VocalStemCache] delete failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

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

    // Loads the cached mono stem for `audioURL`, or nil on miss / unreadable / malformed.
    static func load(for audioURL: URL) -> [Float]? {
        guard let url = cacheURL(for: audioURL), FileManager.default.fileExists(atPath: url.path),
              let samples = readSamples(from: url), samples.isEmpty == false else { return nil }
        // Refresh mtime on a hit so the LRU budget treats a re-aligned song as recently USED, not
        // stale — a frequently re-aligned old song then survives eviction over genuinely cold ones.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return samples
    }

    // Stores the mono stem for `audioURL`. Best-effort: a write failure (e.g. low disk) just means
    // the next align re-isolates. Skips empty input so a failed isolation isn't cached as a valid result.
    static func store(_ samples: [Float], for audioURL: URL) {
        guard samples.isEmpty == false, let url = cacheURL(for: audioURL) else { return }
        guard writeSamples(samples, to: url) else { return }
        // Keep the cache within budget — this store may have pushed it over.
        enforceBudget()
    }

    // Decodes a cached stem file to mono Float32 at its stored rate, a chunk at a time.
    private static func readSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let channel = buffer.floatChannelData?[0] else { return nil }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    // Encodes mono Float32 samples as 16-bit Apple Lossless at `url`. Written beside the target and
    // moved into place, so a crash mid-encode never leaves a truncated stem under the real key.
    private static func writeSamples(_ samples: [Float], to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16,
        ]
        let partial = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            // Scoped so the file is closed (and its header finalized) before the move.
            do {
                let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
                      let channel = buffer.floatChannelData?[0] else { return false }
                var offset = 0
                while offset < samples.count {
                    let count = min(Int(chunkFrames), samples.count - offset)
                    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + offset, count: count) }
                    buffer.frameLength = AVAudioFrameCount(count)
                    try file.write(from: buffer)
                    offset += count
                }
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
    }

    // Evicts least-recently-USED entries until the VocalStems dir is at or under `maxBytes`. LRU is
    // by file modificationDate, which `load()` refreshes on a hit, so a hot song outlives cold ones.
    // Counts every file in the dir. Best-effort and cheap (one directory scan); call on launch and
    // after every store.
    public static func enforceBudget(maxBytes: Int = VocalStemCache.maxBytes) {
        guard let dir = cacheDir() else {
            print("[VocalStemCache] enforceBudget: no cache dir, skipping")
            return
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            print("[VocalStemCache] enforceBudget: contentsOfDirectory failed at \(dir.path)")
            return
        }
        var files: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for url in items {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            files.append((url, size, v.contentModificationDate ?? .distantPast))
            total += size
        }
        let mb = { (b: Int) in String(format: "%.1f MB", Double(b) / 1_048_576) }
        print("[VocalStemCache] enforceBudget scan: \(files.count) files, \(mb(total)) total, cap \(mb(maxBytes)) — at \(dir.path)")
        guard total > maxBytes else { return }
        var evicted = 0
        let startTotal = total
        for f in files.sorted(by: { $0.mtime < $1.mtime }) {   // oldest first
            if total <= maxBytes { break }
            if (try? FileManager.default.removeItem(at: f.url)) != nil {
                total -= f.size
                evicted += 1
            }
        }
        print("[VocalStemCache] enforceBudget evicted \(evicted) files, freed \(mb(startTotal - total)), now \(mb(total))")
    }

    // Whether a cached stem exists for `audioURL` (cheap existence check, no decode) — drives
    // whether the UI offers the "listen to the isolated vocals" affordance.
    public static func hasStem(for audioURL: URL) -> Bool {
        guard let url = cacheURL(for: audioURL) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // The cached stem for `audioURL` as a playable file — the cache entry itself — or nil if no stem
    // is cached yet (the song hasn't been aligned). Lets the UI play back exactly what the aligner
    // hears — the isolated vocals — without re-running isolation.
    public static func playableStemURL(for audioURL: URL) -> URL? {
        guard let url = cacheURL(for: audioURL), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
