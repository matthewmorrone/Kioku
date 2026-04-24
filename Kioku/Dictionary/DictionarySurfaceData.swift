import Foundation

nonisolated public struct DictionarySurfaceData {
    public let surfaceRecords: [SurfaceRecord]
    public let partOfSpeechByEntryID: [Int: UInt64]

    public init(surfaceRecords: [SurfaceRecord], partOfSpeechByEntryID: [Int: UInt64]) {
        self.surfaceRecords = surfaceRecords
        self.partOfSpeechByEntryID = partOfSpeechByEntryID
    }
}
