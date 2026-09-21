import Foundation

// Maps old-form kanji (kyujitai and variant spellings) to their modern shinjitai equivalents so
// text written in an older orthography still matches dictionary entries indexed under the modern
// form. DictionaryTrie applies it while walking the dictionary, so segmentation, lemma resolution
// and metadata lookups all see it; DictionaryStore applies it as a fallback query surface. The
// original spelling is always tried first, and normalization is one scalar to one scalar, so it
// never changes text length or offsets.
nonisolated enum KyujitaiNormalizer {

    // Replaces each old-form scalar in the input with its modern equivalent.
    // Returns nil when no substitution was made, so callers can skip the redundant query.
    static func normalize(_ input: String) -> String? {
        var scalars = input.unicodeScalars
        var changed = false

        for i in scalars.indices {
            if let replacement = modernScalar(for: scalars[i]) {
                scalars.replaceSubrange(i...i, with: CollectionOfOne(replacement))
                changed = true
            }
        }

        return changed ? String(scalars) : nil
    }

    // The one lookup rule for any table keyed by spelling: the surface as written, then its modern
    // spelling. The scan for old-form kanji only runs after a miss, so a hit costs a single probe.
    static func firstHit<Value>(for surface: String, in lookup: (String) -> Value?) -> Value? {
        if let direct = lookup(surface) { return direct }
        guard let modern = normalize(surface) else { return nil }
        return lookup(modern)
    }

    // Returns the modern form of a single old-form character, or nil when the character is not one.
    // Only single-scalar characters are mapped, so a kanji carrying a variation selector or other
    // combining scalar is left alone rather than half-converted.
    static func normalize(_ character: Character) -> Character? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, let replacement = modernScalar(for: scalar) else {
            return nil
        }
        return Character(replacement)
    }

    // Looks one scalar up in the table. Everything below the CJK Extension A block (kana, Latin,
    // punctuation) is rejected up front because this runs on every character the trie walks.
    private static func modernScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        guard scalar.value >= 0x3400 else { return nil }
        return table[scalar]
    }

    // Scalar-keyed table built once from KyujitaiTable's flat old/new pair string.
    private static let table: [Unicode.Scalar: Unicode.Scalar] = buildTable(from: KyujitaiTable.flatPairs)

    // Reads the flat string as consecutive (old, new) scalar pairs, ignoring line breaks and indentation.
    private static func buildTable(from flatPairs: String) -> [Unicode.Scalar: Unicode.Scalar] {
        let scalars = flatPairs.unicodeScalars.filter { $0.properties.isWhitespace == false }
        var result: [Unicode.Scalar: Unicode.Scalar] = [:]
        result.reserveCapacity(scalars.count / 2)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let next = scalars.index(after: index)
            guard next < scalars.endIndex else { break }
            result[scalars[index]] = scalars[next]
            index = scalars.index(after: next)
        }
        return result
    }
}
