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

    // Returns whether the surface exists as a terminal trie path, either exactly as written or after
    // modernizing its old-form kanji (see KyujitaiNormalizer).
    public func contains(_ surface: String) -> Bool {
        let nodes = terminalNodes(for: surface)
        return nodes.literal != nil || nodes.modern != nil
    }

    // Walks a whole surface along two parallel paths — its characters as written (literal) and with
    // each old-form kanji replaced by its modern form (modern) — and returns whichever paths end on a
    // terminal node. The modern path only exists once the surface contains an old-form kanji, so
    // ordinary text costs one path and no allocation.
    private func terminalNodes(for surface: String) -> (literal: Node?, modern: Node?) {
        var literal: Node? = root
        var modern: Node?
        var diverged = false

        for character in surface {
            let mapped = KyujitaiNormalizer.normalize(character)
            if mapped != nil, diverged == false {
                modern = literal
                diverged = true
            }
            literal = literal?.children[character]
            if diverged {
                modern = modern?.children[mapped ?? character]
            }
            if literal == nil && modern == nil { return (nil, nil) }
        }

        let literalTerminal = literal?.isTerminal == true ? literal : nil
        let modernTerminal = diverged && modern?.isTerminal == true ? modern : nil
        return (literalTerminal, modernTerminal)
    }

    // Combines the entry IDs stored on the literal and modern terminal nodes of one surface. When
    // both paths hit, the result is the sorted union, so a word indexed under both spellings
    // resolves to every entry that spelling could mean.
    private func entryIDs(literal: Node?, modern: Node?) -> [Int] {
        var ids: [Int] = []
        if let index = literal?.index { ids += entryIDPool.resolve(index) }
        if let index = modern?.index { ids += entryIDPool.resolve(index) }
        return literal != nil && modern != nil ? Array(Set(ids)).sorted() : ids
    }

    // Returns the OR-merged part-of-speech bitfield for a terminal surface, or 0 when the trie
    // was built without metadata or the surface is not a terminal. Used by the segmenter to
    // populate lattice edges so Viterbi can consult bigram transition costs.
    public func partOfSpeech(for surface: String) -> UInt64 {
        let nodes = terminalNodes(for: surface)
        return (nodes.literal?.partOfSpeech ?? 0) | (nodes.modern?.partOfSpeech ?? 0)
    }

    // Returns the IPADic (left_id, right_id) tagged onto this surface at dictionary-build time
    // via Resources/generate_db.py's import_mecab_context_ids(), or nil when the surface isn't tagged.
    // Used by Segmenter.buildLattice to populate lattice edges so Viterbi can index matrix.bin
    // directly instead of going through POS-class buckets.
    public func ipadicContextIDs(for surface: String) -> (left: Int32, right: Int32)? {
        let nodes = terminalNodes(for: surface)
        for node in [nodes.literal, nodes.modern] {
            if let node, let lid = node.ipadicLeftID, let rid = node.ipadicRightID {
                return (left: lid, right: rid)
            }
        }
        return nil
    }

    // Returns compact entry-id metadata for a surface hit (as written or modernized), or nil when no
    // metadata is stored.
    public func hitMeta(for surface: String) -> TrieHitMeta? {
        let nodes = terminalNodes(for: surface)
        let ids = entryIDs(literal: nodes.literal, modern: nodes.modern)
        return ids.isEmpty ? nil : TrieHitMeta(entryIDs: ids)
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
        var literal: Node? = root
        var modern: Node?
        var diverged = false
        var currentIndex = index
        var traversedLength = 0

        if root.isTerminal {
            matches.append(index..<index)
        }

        // Ranges always index the original text, so a match over old-form kanji still covers exactly
        // the characters as written even when it was found through their modern spelling.
        while currentIndex < text.endIndex && traversedLength < maxLength {
            let character = text[currentIndex]
            let mapped = KyujitaiNormalizer.normalize(character)
            if mapped != nil, diverged == false {
                modern = literal
                diverged = true
            }
            let nextLiteral = literal?.children[character]
            let nextModern = diverged ? modern?.children[mapped ?? character] : nil
            guard nextLiteral != nil || nextModern != nil else { break }
            literal = nextLiteral
            modern = nextModern
            currentIndex = text.index(after: currentIndex)
            traversedLength += 1
            if literal?.isTerminal == true || modern?.isTerminal == true {
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
        var literal: Node? = root
        var modern: Node?
        var diverged = false
        var currentIndex = index
        var traversedLength = 0

        while currentIndex < text.endIndex && traversedLength < maxLength {
            let character = text[currentIndex]
            let mapped = KyujitaiNormalizer.normalize(character)
            if mapped != nil, diverged == false {
                modern = literal
                diverged = true
            }
            let nextLiteral = literal?.children[character]
            let nextModern = diverged ? modern?.children[mapped ?? character] : nil
            guard nextLiteral != nil || nextModern != nil else { break }
            literal = nextLiteral
            modern = nextModern
            currentIndex = text.index(after: currentIndex)
            traversedLength += 1

            // A hit keeps the surface exactly as written; when the word is indexed under both the
            // old and the modern spelling, one hit carries both entries' IDs.
            let literalTerminal = literal?.isTerminal == true ? literal : nil
            let modernTerminal = modern?.isTerminal == true ? modern : nil
            let entryIDs = entryIDs(literal: literalTerminal, modern: modernTerminal)
            if entryIDs.isEmpty == false {
                let surfaceRange = index..<currentIndex
                hits.append(
                    TriePrefixHit(
                        start: surfaceRange.lowerBound,
                        end: surfaceRange.upperBound,
                        surface: String(text[surfaceRange]),
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
            AppLog.debug(.segmentation, "surface=\(surface) hit=nil")
            return
        }
        AppLog.debug(.segmentation, "surface=\(surface) ids=\(hit.entryIDs.count)")
    }
}
