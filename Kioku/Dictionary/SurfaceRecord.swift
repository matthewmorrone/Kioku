import Foundation

nonisolated public struct SurfaceRecord {
    public let surface: String
    public let entryIDs: [Int]
    public let partOfSpeech: UInt64

    public init(surface: String, entryIDs: [Int], partOfSpeech: UInt64) {
        self.surface = surface
        self.entryIDs = entryIDs
        self.partOfSpeech = partOfSpeech
    }
}
