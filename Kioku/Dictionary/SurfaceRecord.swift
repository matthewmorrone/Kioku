import Foundation

nonisolated public struct SurfaceRecord {
    public let surface: String
    public let entryIDs: [Int]
    public let partOfSpeech: UInt64
    // IPADic context IDs harvested at dictionary-build time (see Resources/migrate_add_context_ids.py).
    // The trie-Viterbi path uses these to index directly into matrix.bin instead of going through
    // POS-class buckets. nil when the surface wasn't tagged (missing from IPADic, or build skipped).
    public let ipadicLeftID: Int32?
    public let ipadicRightID: Int32?

    public init(
        surface: String,
        entryIDs: [Int],
        partOfSpeech: UInt64,
        ipadicLeftID: Int32? = nil,
        ipadicRightID: Int32? = nil
    ) {
        self.surface = surface
        self.entryIDs = entryIDs
        self.partOfSpeech = partOfSpeech
        self.ipadicLeftID = ipadicLeftID
        self.ipadicRightID = ipadicRightID
    }
}
