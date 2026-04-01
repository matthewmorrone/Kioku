import Foundation

// Configures lattice size limits and kana filtering for segmentation at each text position.
nonisolated struct SegmenterConfig {
    let maxMatchesPerPosition: Int
    let maxMatchLength: Int
    // Single-character kana allowed as standalone lattice edges; all others are treated as bound morphemes.
    // Defaults to the user's current particle allowlist so settings changes take effect on the next segmentation run.
    let standaloneKana: Set<String>

    // Provides bounded defaults for per-position candidate generation.
    init(
        maxMatchesPerPosition: Int = 16,
        maxMatchLength: Int = 32,
        standaloneKana: Set<String> = ParticleSettings.allowed()
    ) {
        self.maxMatchesPerPosition = maxMatchesPerPosition
        self.maxMatchLength = maxMatchLength
        self.standaloneKana = standaloneKana
    }
}
