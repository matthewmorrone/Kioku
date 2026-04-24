import Foundation

nonisolated public struct TrieHitMeta {
    public let entryIDs: [Int]

    public init(entryIDs: [Int]) {
        self.entryIDs = entryIDs
    }
}
