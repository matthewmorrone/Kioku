import Foundation

// Per-surface reading and frequency data, built once from the materialized surface_readings table.
// Replaces the three separate startup maps (readingBySurface, readingCandidatesBySurface, frequencyDataBySurface).
nonisolated struct SurfaceReadingData: Sendable {
    // Readings ordered by JPDB rank (best first), capped at 8.
    let readings: [String]
    // Frequency metadata keyed by reading. Only populated for readings with at least one frequency signal.
    let frequencyByReading: [String: FrequencyData]
}

// Reference-type wrapper so SwiftUI compares a single pointer instead of diffing 327k dictionary entries.
// The map is built once on a background thread and never mutated after assignment.
// @unchecked Sendable: deeply immutable (a single `let data` set at init, no mutators), so it is safe
// to share across threads — e.g. captured by the subtitle importer's detached furigana-precompute task.
nonisolated final class SurfaceReadingDataMap: Equatable, @unchecked Sendable {
    let data: [String: SurfaceReadingData]

    // Creates an empty map for initial state before resources are loaded.
    init() {
        data = [:]
    }

    // Wraps a fully populated map produced by fetchSurfaceReadingData().
    init(_ data: [String: SurfaceReadingData]) {
        self.data = data
    }

    // Identity-based equality so SwiftUI skips diffing the dictionary contents.
    static func == (lhs: SurfaceReadingDataMap, rhs: SurfaceReadingDataMap) -> Bool {
        lhs === rhs
    }

    // Looks a surface up as written, then in its modern spelling — old-form kanji (氣づく) read
    // the same as the form the table is keyed by (気づく), and the mapping keeps length and offsets.
    subscript(surface: String) -> SurfaceReadingData? {
        KyujitaiNormalizer.firstHit(for: surface) { data[$0] }
    }
}
