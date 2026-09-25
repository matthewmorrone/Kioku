import Combine

// Stores trie child links, terminal state, and compact POS metadata for dictionary surface paths.
nonisolated internal final class Node {
    var children: [Character: Node] = [:]
    var isTerminal: Bool = false
    // Handle into EntryIDPool; non-nil when terminal node was inserted with entry-id metadata.
    var index: Int?
    // Bitfield of PartOfSpeech flags accumulated from all senses of all entries at this node.
    var partOfSpeech: UInt64 = 0
}
