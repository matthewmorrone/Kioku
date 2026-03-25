import Foundation
import SQLite3

// Computes semantic nearest neighbors for a term using cosine similarity over embeddings
// stored in the dictionary SQLite database.
// Used by ClozeStudyViewModel to build plausible distractor options for blank slots.
// Gracefully returns nil when the embeddings table is absent — cloze falls back to sentence tokens.
actor EmbeddingNeighborsService {
    static let shared = EmbeddingNeighborsService()

    // A word and its cosine similarity score relative to the query term.
    struct Neighbor: Hashable {
        let word: String
        let score: Float
    }

    private struct CacheEntry {
        let neighbors: [Neighbor]
        let computedTopN: Int
    }

    private var allWordsLoaded = false
    private var allWords: [String] = []
    private let embeddingDim = 300

    private var cache: [String: CacheEntry] = [:]
    private var knownMissing: Set<String> = []
    private var inFlight: [String: Task<[Neighbor]?, Never>] = [:]

    // Returns up to topN nearest neighbors for term, or nil when no embedding is available.
    // Results are session-cached aggressively to avoid redundant SQLite scans.
    func neighbors(for term: String, topN: Int = 30) async -> [Neighbor]? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let n = max(0, min(100, topN))
        guard n > 0 else { return [] }
        if knownMissing.contains(trimmed) { return nil }
        if let cached = cache[trimmed], cached.computedTopN >= n {
            return Array(cached.neighbors.prefix(n))
        }
        if let existing = inFlight[trimmed] {
            let result = await existing.value
            return result.map { Array($0.prefix(n)) }
        }

        guard let dbPath = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3")?.path else {
            return nil
        }

        let base = await Task.detached(priority: .utility) { [embeddingDim] in
            Self.fetchVectorsSync(for: [trimmed], dbPath: dbPath, dim: embeddingDim)[trimmed]
        }.value

        guard let base else { knownMissing.insert(trimmed); return nil }

        let words = await loadAllWordsIfNeeded()
        if words.isEmpty { return [] }

        let task = Task<[Neighbor]?, Never>(priority: .userInitiated) { [embeddingDim] in
            let candidates = words.filter { $0 != trimmed }
            var best: [Neighbor] = []
            best.reserveCapacity(n)

            let chunkSize = 300
            var idx = 0
            while idx < candidates.count {
                let end = Swift.min(candidates.count, idx + chunkSize)
                let chunk = Array(candidates[idx..<end])
                idx = end

                let vectors = await Task.detached(priority: .utility) {
                    Self.fetchVectorsSync(for: chunk, dbPath: dbPath, dim: embeddingDim)
                }.value

                for (k, v) in vectors {
                    let score = Self.dot(base, v)
                    Self.insertNeighbor(Neighbor(word: k, score: score), into: &best, topN: n)
                }
            }

            return best
        }

        inFlight[trimmed] = task
        let computed = await task.value
        inFlight[trimmed] = nil

        guard let computed else { return nil }
        cache[trimmed] = CacheEntry(neighbors: computed, computedTopN: n)
        return Array(computed.prefix(n))
    }

    // Dot product over equal-length float vectors; assumes L2-normalized embeddings.
    private nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var acc: Float = 0
        for i in 0..<a.count { acc += a[i] * b[i] }
        return acc
    }

    // Fetches raw float vectors for a batch of keys from the embeddings table.
    private nonisolated static func fetchVectorsSync(
        for keys: [String],
        dbPath: String,
        dim: Int
    ) -> [String: [Float]] {
        guard keys.isEmpty == false else { return [:] }
        let expectedBytes = dim * MemoryLayout<Float>.size
        var out: [String: [Float]] = [:]
        out.reserveCapacity(keys.count)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle
        else { sqlite3_close(handle); return [:] }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = "SELECT word, vec FROM embeddings WHERE word IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return [:]
        }
        defer { sqlite3_finalize(stmt) }

        for (i, key) in keys.enumerated() {
            let rc = sqlite3_bind_text(stmt, Int32(i + 1), key, -1,
                                       unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard rc == SQLITE_OK else { return [:] }
        }

        var stepCode = sqlite3_step(stmt)
        while stepCode == SQLITE_ROW {
            guard let wordPtr = sqlite3_column_text(stmt, 0),
                  let blob = sqlite3_column_blob(stmt, 1),
                  Int(sqlite3_column_bytes(stmt, 1)) == expectedBytes
            else { stepCode = sqlite3_step(stmt); continue }

            let word = String(cString: wordPtr)
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blob),
                            count: expectedBytes, deallocator: .none)
            let vec: [Float]? = data.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                guard floats.count == dim else { return nil }
                return Array(floats)
            }
            if let vec { out[word] = vec }
            stepCode = sqlite3_step(stmt)
        }

        return out
    }

    // Loads the full vocabulary list from the embeddings table once per session.
    private func loadAllWordsIfNeeded() async -> [String] {
        if allWordsLoaded { return allWords }

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            return []
        }

        let loaded: [String] = await Task.detached(priority: .utility) {
            var words: [String] = []
            words.reserveCapacity(30_000)

            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let db = handle
            else { sqlite3_close(handle); return [] }
            defer { sqlite3_close(db) }

            let sql = "SELECT word FROM embeddings;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }

            var stepCode = sqlite3_step(stmt)
            while stepCode == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) { words.append(String(cString: ptr)) }
                stepCode = sqlite3_step(stmt)
            }

            return words
        }.value

        allWords = loaded
        allWordsLoaded = true
        return loaded
    }

    // Maintains a top-N heap by replacing the worst entry when a better neighbor arrives.
    private static func insertNeighbor(_ n: Neighbor, into arr: inout [Neighbor], topN: Int) {
        guard topN > 0 else { return }
        if arr.count < topN {
            arr.append(n)
            arr.sort { $0.score > $1.score }
            return
        }
        guard let worst = arr.last, n.score > worst.score else { return }
        arr[arr.count - 1] = n
        arr.sort { $0.score > $1.score }
    }
}
