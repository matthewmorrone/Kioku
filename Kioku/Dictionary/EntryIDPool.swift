import Foundation

nonisolated public final class EntryIDPool {
    private var pool: [[Int]] = []
    private var handlesByKey: [String: Int] = [:]
    // False after restoring a saved pool, until the first intern rebuilds the key index; a trie
    // loaded from a snapshot rarely interns again, so the index isn't built up front.
    private var handlesByKeyIsCurrent = true

    // An empty pool.
    public init() {}

    // A pool holding exactly `slices`, each at the handle it had when saved (DictionaryTrie+Snapshot).
    init(restoring slices: [[Int]]) {
        pool = slices
        handlesByKeyIsCurrent = false
    }

    // Every interned slice in handle order, for DictionaryTrie+Snapshot.
    var slices: [[Int]] { pool }

    // Interns one entry-id slice and returns a compact reusable handle.
    public func intern(_ ids: [Int]) -> Int {
        if handlesByKeyIsCurrent == false {
            handlesByKey = Dictionary(pool.enumerated().map { (keyForIDs($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
            handlesByKeyIsCurrent = true
        }
        let normalizedIDs = normalized(ids)
        let key = keyForIDs(normalizedIDs)
        if let existingHandle = handlesByKey[key] { return existingHandle }
        let handle = pool.count
        pool.append(normalizedIDs)
        handlesByKey[key] = handle
        return handle
    }

    // Resolves a previously interned handle into its deduplicated entry-id slice.
    public func resolve(_ handle: Int) -> [Int] {
        guard handle >= 0 && handle < pool.count else { return [] }
        return pool[handle]
    }

    // Returns the current number of interned unique id-slices for diagnostics.
    public var count: Int { pool.count }

    // Deduplicates and sorts the input so order-insensitive id-slices intern to the same handle.
    private func normalized(_ ids: [Int]) -> [Int] { Array(Set(ids)).sorted() }
    // Derives a stable dictionary key from a normalized id-slice so intern lookups are O(1).
    private func keyForIDs(_ ids: [Int]) -> String { ids.map { String($0) }.joined(separator: ",") }
}
