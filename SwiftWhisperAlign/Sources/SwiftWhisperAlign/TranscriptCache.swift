import Foundation

// Resumable checkpoint for the anchor-transcription stage. Each ~24 s ASR piece is the single most
// expensive, jetsam-prone step (a ~60 s model load + an MLX forward pass per piece) — and historically
// where the OS OOM-killed us mid-run. This persists every completed piece the instant it finishes, so
// a kill (jetsam, suspension, force-quit) loses at most the in-flight piece: the next align reloads the
// finished pieces off disk and resumes from where it died, and a fully-cached transcript skips even the
// model load. Keyed by the same content identity as the stem (VocalStemCache.identityKey) plus a
// signature of the region layout + piece size, so it only ever hits when the inputs are byte-identical.
//
// Mirrors VocalStemCache: lives under Caches/ (OS-reclaimable; a miss just re-transcribes), writes are
// best-effort + atomic. A piece carries its own [start,end] so resume matches by time, not array index.
public enum TranscriptCache {

    public struct Piece: Codable, Equatable {
        public let start: Double
        public let end: Double
        public let text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start; self.end = end; self.text = text
        }
    }

    private static let formatVersion = 1

    private static func cacheDir() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("AnchorTranscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Filename = audio identity + a signature of the params that change the transcription (region
    // boundaries + piece length + format version). Identical inputs → one stable entry; any change in
    // the VAD regions or piece size lands on a fresh key, so a stale transcript can never be reused.
    private static func cacheURL(identity: String, regions: [(start: Double, end: Double)], pieceSec: Double) -> URL? {
        guard let dir = cacheDir() else { return nil }
        let sig = signature(regions: regions, pieceSec: pieceSec)
        return dir.appendingPathComponent("\(identity)-\(sig).json")
    }

    // Deterministic 64-bit FNV-1a over the region layout + piece size, hex-encoded — fixed-length and
    // stable across launches (unlike Swift's per-launch-randomized hashValue).
    static func signature(regions: [(start: Double, end: Double)], pieceSec: Double) -> String {
        var s = "v\(formatVersion)|p\(Int((pieceSec * 1000).rounded()))|"
        for r in regions { s += "\(Int((r.start * 1000).rounded()))-\(Int((r.end * 1000).rounded()))," }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    // Loads the completed pieces for this exact (audio, regions, pieceSec), or [] on miss/unreadable.
    public static func load(identity: String, regions: [(start: Double, end: Double)], pieceSec: Double) -> [Piece] {
        guard let url = cacheURL(identity: identity, regions: regions, pieceSec: pieceSec),
              let data = try? Data(contentsOf: url),
              let pieces = try? JSONDecoder().decode([Piece].self, from: data) else { return [] }
        return pieces
    }

    // Overwrites the checkpoint with the full set of pieces completed so far. Called after each piece,
    // so the file always reflects every finished piece. Best-effort: a write failure just means the
    // next align redoes from the last successful checkpoint (or from scratch).
    public static func store(_ pieces: [Piece], identity: String, regions: [(start: Double, end: Double)], pieceSec: Double) {
        guard let url = cacheURL(identity: identity, regions: regions, pieceSec: pieceSec),
              let data = try? JSONEncoder().encode(pieces) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Drops the checkpoint once the transcript has been fully consumed into anchors, so a later
    // re-align of edited lyrics re-transcribes cleanly. Best-effort.
    public static func clear(identity: String, regions: [(start: Double, end: Double)], pieceSec: Double) {
        guard let url = cacheURL(identity: identity, regions: regions, pieceSec: pieceSec) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
