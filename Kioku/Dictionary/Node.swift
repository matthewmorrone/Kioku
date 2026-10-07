import Foundation

// Stores trie child links, terminal state, and compact POS metadata for dictionary surface paths.
// Children are keyed by Unicode scalar value, not Character: hashing a UInt32 is far cheaper than
// hashing a grapheme cluster, and dictionary and note text is almost all single-scalar kana and
// kanji. A Character of several scalars is walked one scalar per level, after NFC composition so
// canonically equal spellings (か + ゛ and が) still meet on one path.
nonisolated internal final class Node {
    var children: [UInt32: Node] = [:]
    var isTerminal: Bool = false
    // Handle into EntryIDPool; non-nil when terminal node was inserted with entry-id metadata.
    var index: Int?
    // Bitfield of PartOfSpeech flags accumulated from all senses of all entries at this node.
    var partOfSpeech: UInt64 = 0

    // The node reached by stepping over `character`, or nil when no surface continues that way.
    func child(_ character: Character) -> Node? {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            return children[scalar.value]
        }
        var node: Node? = self
        for scalar in Node.composedScalars(of: character) {
            node = node?.children[scalar]
        }
        return node
    }

    // The node reached by stepping over `character`, creating the missing links; used on insert.
    func childCreating(_ character: Character) -> Node {
        var node = self
        for scalar in Node.composedScalars(of: character) {
            if let next = node.children[scalar] {
                node = next
            } else {
                let next = Node()
                node.children[scalar] = next
                node = next
            }
        }
        return node
    }

    // The scalar values of `character` in NFC, so a decomposed spelling keys like its composed one.
    private static func composedScalars(of character: Character) -> [UInt32] {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first { return [scalar.value] }
        return String(character).precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
    }
}
