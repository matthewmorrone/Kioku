nonisolated public final class DictionaryTrie {
    private let root = Node()
    private let entryIDPool = EntryIDPool()
    public private(set) var surfaceCount: Int = 0
    public private(set) var maxSurfaceLength: Int = 0

    // Creates an empty trie for dictionary surface indexing.
    public init() {}

    // Creates a trie and inserts each provided surface string without metadata.
    public convenience init<S: Sequence>(_ surfaces: S) where S.Element == String {
        self.init()
        for surface in surfaces {
            insert(surface)
        }
    }

    // Creates a trie and inserts each provided surface record with compact POS/entry-id metadata.
    public convenience init<S: Sequence>(records: S) where S.Element == SurfaceRecord {
        self.init()
        for record in records {
            insert(record)
        }
    }

    // Inserts a surface without metadata.
    public func insert(_ surface: String) {
        insert(surface, entryIDs: [], partOfSpeech: 0, ipadicLeftID: nil, ipadicRightID: nil)
    }

    // Inserts one surface record so terminal nodes retain compact entry-id and POS metadata.
    public func insert(_ record: SurfaceRecord) {
        insert(
            record.surface,
            entryIDs: record.entryIDs,
            partOfSpeech: record.partOfSpeech,
            ipadicLeftID: record.ipadicLeftID,
            ipadicRightID: record.ipadicRightID
        )
    }

    // Inserts a surface with optional metadata, merging entry IDs if the surface already exists.
    public func insert(
        _ surface: String,
        entryIDs: [Int],
        partOfSpeech: UInt64,
        ipadicLeftID: Int32? = nil,
        ipadicRightID: Int32? = nil
    ) {
        var node = root
        var length = 0

        for character in surface {
            length += 1
            if let next = node.children[character] {
                node = next
            } else {
                let next = Node()
                node.children[character] = next
                node = next
            }
        }

        let incomingHandle = entryIDs.isEmpty ? nil : entryIDPool.intern(entryIDs)
        if let incomingHandle {
            if let existingHandle = node.index {
                let existingIDs = entryIDPool.resolve(existingHandle)
                let mergedIDs = Array(Set(existingIDs + entryIDs)).sorted()
                node.index = entryIDPool.intern(mergedIDs)
            } else {
                node.index = incomingHandle
            }
        }

        node.partOfSpeech |= partOfSpeech
        // Last writer wins for context IDs — same surface inserted twice with different IDs is
        // rare (only happens if generate_db.py changes how it harvests). MeCab's lookup gives one
        // (left_id, right_id) per surface, so consecutive inserts for the same surface should match.
        if let ipadicLeftID { node.ipadicLeftID = ipadicLeftID }
        if let ipadicRightID { node.ipadicRightID = ipadicRightID }

        if !node.isTerminal {
            node.isTerminal = true
            surfaceCount += 1
            if length > maxSurfaceLength {
                maxSurfaceLength = length
            }
        }
    }

    // Returns whether the exact surface exists as a terminal trie path.
    public func contains(_ surface: String) -> Bool {
        var node = root
        for character in surface {
            guard let next = node.children[character] else { return false }
            node = next
        }
        return node.isTerminal
    }

    // Returns the OR-merged part-of-speech bitfield for a terminal surface, or 0 when the trie
    // was built without metadata or the surface is not a terminal. Used by the segmenter to
    // populate lattice edges so Viterbi can consult bigram transition costs.
    public func partOfSpeech(for surface: String) -> UInt64 {
        var node = root
        for character in surface {
            guard let next = node.children[character] else { return 0 }
            node = next
        }
        return node.isTerminal ? node.partOfSpeech : 0
    }

    // Returns the IPADic (left_id, right_id) tagged onto this surface at dictionary-build time
    // via Resources/migrate_add_context_ids.py, or nil when the surface isn't tagged.
    // Used by Segmenter.buildLattice to populate lattice edges so Viterbi can index matrix.bin
    // directly instead of going through POS-class buckets.
    public func ipadicContextIDs(for surface: String) -> (left: Int32, right: Int32)? {
        var node = root
        for character in surface {
            guard let next = node.children[character] else { return nil }
            node = next
        }
        guard node.isTerminal, let lid = node.ipadicLeftID, let rid = node.ipadicRightID else {
            return nil
        }
        return (left: lid, right: rid)
    }

    // Returns compact entry-id metadata for an exact surface hit, or nil when no metadata is stored.
    public func hitMeta(for surface: String) -> TrieHitMeta? {
        var node = root
        for character in surface {
            guard let next = node.children[character] else { return nil }
            node = next
        }
        guard node.isTerminal, let index = node.index else { return nil }
        return TrieHitMeta(entryIDs: entryIDPool.resolve(index))
    }
    // Returns all surface match ranges starting at the given text index.
    public func prefixMatches(in text: String, startingAt index: String.Index) -> [Range<String.Index>] {
        prefixScan(in: text, startingAt: index, maxLength: maxSurfaceLength).matches
    }

    // Returns terminal prefix hits with surface text and compact entry-id metadata.
    public func prefixHits(in text: String, startingAt index: String.Index) -> [TriePrefixHit] {
        prefixHitScan(in: text, startingAt: index, maxLength: maxSurfaceLength).hits
    }

    // Returns terminal prefix matches and the farthest index reached during trie walking.
    public func prefixScan(
        in text: String,
        startingAt index: String.Index,
        maxLength: Int
    ) -> (matches: [Range<String.Index>], scannedEnd: String.Index) {
        guard index <= text.endIndex else {
            return (matches: [], scannedEnd: text.endIndex)
        }

        var matches: [Range<String.Index>] = []
        var node = root
        var currentIndex = index
        var traversedLength = 0

        if node.isTerminal {
            matches.append(index..<index)
        }

        while currentIndex < text.endIndex && traversedLength < maxLength {
            let character = text[currentIndex]
            guard let next = node.children[character] else { break }
            node = next
            currentIndex = text.index(after: currentIndex)
            traversedLength += 1
            if node.isTerminal {
                matches.append(index..<currentIndex)
            }
        }

        return (matches: matches, scannedEnd: currentIndex)
    }

    // Returns terminal prefix hits with compact entry-id metadata and the farthest index reached.
    public func prefixHitScan(
        in text: String,
        startingAt index: String.Index,
        maxLength: Int
    ) -> (hits: [TriePrefixHit], scannedEnd: String.Index) {
        guard index <= text.endIndex else {
            return (hits: [], scannedEnd: text.endIndex)
        }

        var hits: [TriePrefixHit] = []
        var node = root
        var currentIndex = index
        var traversedLength = 0

        while currentIndex < text.endIndex && traversedLength < maxLength {
            let character = text[currentIndex]
            guard let next = node.children[character] else { break }
            node = next
            currentIndex = text.index(after: currentIndex)
            traversedLength += 1

            if node.isTerminal, let entryIndex = node.index {
                let surfaceRange = index..<currentIndex
                let surface = String(text[surfaceRange])
                let entryIDs = entryIDPool.resolve(entryIndex)
                hits.append(
                    TriePrefixHit(
                        start: surfaceRange.lowerBound,
                        end: surfaceRange.upperBound,
                        surface: surface,
                        indices: entryIDs
                    )
                )
            }
        }

        return (hits: hits, scannedEnd: currentIndex)
    }

    // Resolves one pooled entry-id handle into stable entry IDs for downstream lookup steps.
    public func resolveEntryIDs(handle: Int) -> [Int] {
        entryIDPool.resolve(handle)
    }

    // Prints compact terminal metadata for one exact surface to validate trie metadata wiring.
    public func debugPrintHitMeta(for surface: String) {
        guard let hit = hitMeta(for: surface) else {
            print("surface=\(surface) hit=nil")
            return
        }
        print("surface=\(surface) ids=\(hit.entryIDs.count)")
    }
}
