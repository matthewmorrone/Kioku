import Foundation

// Configures lattice size limits and kana filtering for segmentation at each text position.
nonisolated struct SegmenterConfig {
    let maxMatchesPerPosition: Int
    let maxMatchLength: Int
    // Single-character kana the greedy walk allows as standalone lattice edges; all others are treated as
    // bound morphemes. The path search does not consult it.
    let standaloneKana: Set<String>

    // Provides bounded defaults for per-position candidate generation.
    init(
        maxMatchesPerPosition: Int = 16,
        maxMatchLength: Int = 32,
        standaloneKana: Set<String> = KanaData.particleSet
    ) {
        self.maxMatchesPerPosition = maxMatchesPerPosition
        self.maxMatchLength = maxMatchLength
        self.standaloneKana = standaloneKana
    }
}
