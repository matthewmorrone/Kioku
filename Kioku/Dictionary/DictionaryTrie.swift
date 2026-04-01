nonisolated public final class DictionaryTrie {
    private let root = Node()
    public private(set) var surfaceCount: Int = 0
    public private(set) var maxSurfaceLength: Int = 0

    // Creates an empty trie for dictionary surface indexing.
    public init() {}

    // Creates a trie and inserts each provided surface.
    public convenience init<S: Sequence>(_ surfaces: S) where S.Element == String {
        self.init()
        for surface in surfaces {
            insert(surface)
        }
    }

    // Inserts a surface into the trie and updates aggregate counters.
    public func insert(_ surface: String) {
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
            guard let next = node.children[character] else {
                return false
            }
            node = next
        }

        return node.isTerminal
    }

    // Returns all surface match ranges starting at the given text index.
    public func prefixMatches(in text: String, startingAt index: String.Index) -> [Range<String.Index>] {
        prefixScan(in: text, startingAt: index, maxLength: maxSurfaceLength).matches
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
            guard let next = node.children[character] else {
                break
            }

            node = next
            currentIndex = text.index(after: currentIndex)
            traversedLength += 1

            if node.isTerminal {
                matches.append(index..<currentIndex)
            }
        }

        return (matches: matches, scannedEnd: currentIndex)
    }
}
