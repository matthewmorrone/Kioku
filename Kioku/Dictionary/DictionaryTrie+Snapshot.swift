import Foundation

// Saves a built trie to a compact binary file and restores it, so a launch can skip rebuilding the
// trie from the dictionary's 456k surface records (about a second on a phone). The file is tied to
// one dictionary file by `dictionaryKey`; any other key, version or a malformed file restores nil and
// the caller rebuilds. Layout, little-endian: magic, version, key, counts, the entry-id pool, then
// every node depth-first (flags, pool handle, POS bits, child count, each child's scalar and node).
extension DictionaryTrie {
    private static let snapshotMagic: UInt32 = 0x4B545249  // "KTRI"
    // Bump when insert, Node or EntryIDPool change what a built trie holds, so older files are rebuilt.
    private static let snapshotVersion: UInt32 = 1

    // A key identifying `databaseURL`'s exact file: its size and modification time. A replaced or
    // re-downloaded dictionary gets a new key, so an old snapshot is never used against it.
    static func snapshotKey(forDatabaseAt databaseURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)-\(Int64(modified.timeIntervalSince1970 * 1000))"
    }

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
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            writer.append(UInt8((node.isTerminal ? 1 : 0) | (node.index != nil ? 2 : 0)))
            if let index = node.index { writer.append(UInt32(index)) }
            writer.append(node.partOfSpeech)
            // Children in scalar order so the same trie always writes the same bytes; pushed in
            // reverse so they pop, and are written, in that order.
            let children = node.children.sorted { $0.key < $1.key }
            writer.append(UInt32(children.count))
            for (scalar, _) in children { writer.append(scalar) }
            stack.append(contentsOf: children.reversed().map(\.value))
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

    // Reads the depth-first node records back into nodes, returning the root. Each pending entry
    // is a parent waiting for its next child, with the scalars still to attach.
    private static func readNodes(_ reader: inout SnapshotReader) -> Node? {
        var root: Node?
        var pending: [(parent: Node, scalars: [UInt32], next: Int)] = []
        repeat {
            guard let flags = reader.uint8() else { return nil }
            let node = Node()
            node.isTerminal = flags & 1 != 0
            if flags & 2 != 0 {
                guard let index = reader.uint32() else { return nil }
                node.index = Int(index)
            }
            guard let partOfSpeech = reader.uint64(), let childCount = reader.uint32() else { return nil }
            node.partOfSpeech = partOfSpeech
            var scalars: [UInt32] = []
            scalars.reserveCapacity(Int(childCount))
            for _ in 0..<childCount {
                guard let scalar = reader.uint32() else { return nil }
                scalars.append(scalar)
            }
            if pending.isEmpty, root == nil {
                root = node
            } else if let last = pending.indices.last {
                pending[last].parent.children[pending[last].scalars[pending[last].next]] = node
                pending[last].next += 1
            } else {
                return nil
            }
            if scalars.isEmpty == false {
                node.children.reserveCapacity(scalars.count)
                pending.append((parent: node, scalars: scalars, next: 0))
            }
            while let last = pending.last, last.next == last.scalars.count {
                pending.removeLast()
            }
        } while pending.isEmpty == false
        return root
    }
}
