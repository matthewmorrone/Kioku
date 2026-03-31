import Foundation

// Per-surface reading and frequency data, built once from the materialized surface_readings table.
// Replaces the three separate startup maps (readingBySurface, readingCandidatesBySurface, frequencyDataBySurface).
struct SurfaceReadingData {
    // Readings ordered by JPDB rank (best first), capped at 8.
    let readings: [String]
    // Frequency metadata keyed by reading. Only populated for readings with at least one frequency signal.
    let frequencyByReading: [String: FrequencyData]
}

// Reference-type wrapper so SwiftUI compares a single pointer instead of diffing 327k dictionary entries.
// The map is built once on a background thread and never mutated after assignment.
final class SurfaceReadingDataMap: Equatable {
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

    // Subscript passthrough for ergonomic access.
    subscript(surface: String) -> SurfaceReadingData? {
        data[surface]
    }
}
