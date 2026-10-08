import Foundation

// Saves a built trie to a compact binary file and restores it, so a launch can skip rebuilding the
// trie from the dictionary's 456k surface records (about a second on a phone). The file is tied to
// what the trie was built from by `dictionaryKey` (TrieSnapshotCache.key); any other key, version
// or a malformed file restores nil and the caller rebuilds. Layout, little-endian: magic, version,
// key, counts, the entry-id pool, then every node depth-first (flags, pool handle, POS bits, child
// count), each child's record preceded by the scalar that leads to it, so reading needs no per-node
// scratch arrays.
nonisolated extension DictionaryTrie {
    private static let snapshotMagic: UInt32 = 0x4B545249  // "KTRI"
    // Bump when insert, Node or EntryIDPool change what a built trie holds, so older files are rebuilt.
    private static let snapshotVersion: UInt32 = 2

    // The trie as snapshot bytes, tagged with `dictionaryKey`.
    func snapshotData(dictionaryKey: String) -> Data {
        var writer = SnapshotWriter()
        writer.append(Self.snapshotMagic)
        writer.append(Self.snapshotVersion)
        writer.append(dictionaryKey)
        writer.append(UInt32(surfaceCount))
        writer.append(UInt32(maxSurfaceLength))
        let slices = entryIDPool.slices
        writer.append(UInt32(slices.count))
        for slice in slices {
            writer.append(UInt32(slice.count))
            for id in slice { writer.append(UInt32(id)) }
        }
        // Each stack item is a node to write and the scalar leading to it (nil for the root).
        var stack: [(scalar: UInt32?, node: Node)] = [(nil, root)]
        while let (scalar, node) = stack.popLast() {
            if let scalar { writer.append(scalar) }
            writer.append(UInt8((node.isTerminal ? 1 : 0) | (node.index != nil ? 2 : 0)))
            if let index = node.index { writer.append(UInt32(index)) }
            writer.append(node.partOfSpeech)
            // Children in scalar order so the same trie always writes the same bytes; pushed in
            // reverse so they pop, and are written, in that order.
            let children = node.children.sorted { $0.key < $1.key }
            writer.append(UInt32(children.count))
            stack.append(contentsOf: children.reversed().map { (scalar: $0.key, node: $0.value) })
        }
        return writer.data
    }

    // The trie saved in `data`, or nil unless it is a well-formed snapshot of this version tagged
    // with `dictionaryKey`.
    static func restored(from data: Data, dictionaryKey: String) -> DictionaryTrie? {
        data.withUnsafeBytes { buffer -> DictionaryTrie? in
            var reader = SnapshotReader(buffer: buffer)
            guard reader.uint32() == snapshotMagic, reader.uint32() == snapshotVersion,
                  reader.string() == dictionaryKey,
                  let surfaceCount = reader.uint32(), let maxSurfaceLength = reader.uint32(),
                  let sliceCount = reader.uint32() else { return nil }
            var slices: [[Int]] = []
            slices.reserveCapacity(Int(sliceCount))
            for _ in 0..<sliceCount {
                guard let count = reader.uint32() else { return nil }
                var slice: [Int] = []
                slice.reserveCapacity(Int(count))
                for _ in 0..<count {
                    guard let id = reader.uint32() else { return nil }
                    slice.append(Int(id))
                }
                slices.append(slice)
            }
            guard let root = readNodes(&reader), reader.isAtEnd else { return nil }
            let trie = DictionaryTrie()
            trie.root = root
            trie.entryIDPool = EntryIDPool(restoring: slices)
            trie.surfaceCount = Int(surfaceCount)
            trie.maxSurfaceLength = Int(maxSurfaceLength)
            return trie
        }
    }

    // Reads the depth-first node records back into nodes, returning the root. Each pending entry is
    // a parent and how many of its children are still to read.
    private static func readNodes(_ reader: inout SnapshotReader) -> Node? {
        guard let root = readNode(&reader) else { return nil }
        var pending: [(node: Node, remaining: UInt32)] = []
        if root.remaining > 0 { pending.append(root) }
        while let last = pending.indices.last {
            guard let scalar = reader.uint32(), let child = readNode(&reader) else { return nil }
            pending[last].node.children[scalar] = child.node
            pending[last].remaining -= 1
            if pending[last].remaining == 0 { pending.removeLast() }
            if child.remaining > 0 { pending.append(child) }
        }
        return root.node
    }

    // One node record: the node, with its child table sized, and how many children follow it.
    private static func readNode(_ reader: inout SnapshotReader) -> (node: Node, remaining: UInt32)? {
        guard let flags = reader.uint8() else { return nil }
        let node = Node()
        node.isTerminal = flags & 1 != 0
        if flags & 2 != 0 {
            guard let index = reader.uint32() else { return nil }
            node.index = Int(index)
        }
        guard let partOfSpeech = reader.uint64(), let childCount = reader.uint32() else { return nil }
        node.partOfSpeech = partOfSpeech
        if childCount > 0 { node.children.reserveCapacity(Int(childCount)) }
        return (node, childCount)
    }
}
