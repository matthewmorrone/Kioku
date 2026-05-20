import Foundation

// One radical component (e.g. 木, 心, 亻) along with its stroke count, sourced from EDRDG RADKFILE2.
// Distinct from KANJIDIC2's per-character Kangxi `radical` number — Radical describes a *component*
// that can appear in many kanji, used for multi-radical lookup ("find kanji containing 心 AND 木").
nonisolated public struct Radical: Equatable, Hashable, Identifiable {
    public var id: String { glyph }
    public let glyph: String
    public let strokeCount: Int

    public init(glyph: String, strokeCount: Int) {
        self.glyph = glyph
        self.strokeCount = strokeCount
    }
}
