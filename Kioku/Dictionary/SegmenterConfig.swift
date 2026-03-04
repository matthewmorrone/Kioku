import Foundation

// Configures lattice size limits for segmentation at each text position.
struct SegmenterConfig {
    let maxMatchesPerPosition: Int
    let maxMatchLength: Int

    // Provides bounded defaults for per-position candidate generation.
    init(maxMatchesPerPosition: Int = 16, maxMatchLength: Int = 32) {
        self.maxMatchesPerPosition = maxMatchesPerPosition
        self.maxMatchLength = maxMatchLength
    }
}
