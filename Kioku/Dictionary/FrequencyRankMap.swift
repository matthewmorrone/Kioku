import Foundation

// Surface → best JPDB rank (lower = more frequent), propagated PER ENTRY across every writing.
//
// This is the same per-entry-propagated signal the segmenter consumes via
// fetchFrequencyScoreBySurface(): JPDB ranks a single written form per entry (usually the kanji
// headword), so a kana spelling or alternate writing has no rank of its own. The materialized
// `surface_readings` table reflects that raw shape — its kana rows carry NULL jpdb_rank — which is
// why the split editor (which reads surface_readings) renders a bare "–" for common kana pieces
// like こと / する / の even though they are extremely frequent. This map is the propagated fallback
// those lookups consult so a piece still reports its entry's frequency.
//
// Reference-type wrapper, mirroring SurfaceReadingDataMap / KanjiReadingFallbackMap, so SwiftUI
// compares a single pointer instead of diffing the (hundreds of thousands of) entries. Built once
// on a background thread and never mutated after assignment.
nonisolated final class FrequencyRankMap: Equatable {
    let data: [String: Int]

    // Creates an empty map for initial state before resources are loaded (and for tests/previews,
    // where the empty map simply disables the fallback).
    init() {
        data = [:]
    }

    // Wraps a fully populated map produced by fetchBestRankBySurface().
    init(_ data: [String: Int]) {
        self.data = data
    }

    var isEmpty: Bool {
        data.isEmpty
    }

    // Identity-based equality so SwiftUI skips diffing the dictionary contents.
    static func == (lhs: FrequencyRankMap, rhs: FrequencyRankMap) -> Bool {
        lhs === rhs
    }

    // Subscript passthrough for ergonomic per-surface access.
    subscript(surface: String) -> Int? {
        data[surface]
    }
}
