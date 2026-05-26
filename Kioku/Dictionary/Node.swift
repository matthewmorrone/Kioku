import Combine

// Stores trie child links, terminal state, and compact POS metadata for dictionary surface paths.
nonisolated internal final class Node {
    var children: [Character: Node] = [:]
    var isTerminal: Bool = false
    // Handle into EntryIDPool; non-nil when terminal node was inserted with entry-id metadata.
    var index: Int?
    // Bitfield of PartOfSpeech flags accumulated from all senses of all entries at this node.
    var partOfSpeech: UInt64 = 0
    // IPADic context IDs for direct matrix.bin lookup at Viterbi time. nil when the surface was
    // inserted without context-ID metadata (older dictionaries, or test fixtures that bypass
    // SurfaceRecord). Stored as Int32 since IPADic's context space tops out at 1316.
    var ipadicLeftID: Int32? = nil
    var ipadicRightID: Int32? = nil
}
