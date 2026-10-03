import Foundation

// Maps spellings the dictionary doesn't index to the ones it does, so text written that way still
// matches its entries:
//   - old-form kanji (kyujitai and variant spellings) to their modern shinjitai equivalents (國 → 国);
//   - katakana standing in for hiragana inside a word that has kanji (高慢チキ → 高慢ちき), as
//     older and playful writing does. Only inside a word with kanji: on its own, katakana is how
//     loanwords are written, and カ must never match the particle か.
// DictionaryTrie applies it while walking the dictionary, so segmentation, lemma resolution and
// metadata lookups all see it; DictionaryStore applies it as a fallback query surface. The original
// spelling is always tried first, and normalization is one scalar to one scalar, so it never changes
// text length or offsets.
nonisolated enum SpellingNormalizer {

    // Replaces each old-form scalar with its modern equivalent and, when the result has a kanji,
    // each katakana scalar with its hiragana. Returns nil when no substitution was made, so callers
    // can skip the redundant query.
    static func normalize(_ input: String) -> String? {
        var scalars = input.unicodeScalars
        var changed = false

        for i in scalars.indices {
            if let replacement = modernScalar(for: scalars[i]) {
                scalars.replaceSubrange(i...i, with: CollectionOfOne(replacement))
                changed = true
            }
        }

        if scalars.contains(where: isKanji) {
            for i in scalars.indices {
                if let replacement = hiraganaScalar(for: scalars[i]) {
                    scalars.replaceSubrange(i...i, with: CollectionOfOne(replacement))
                    changed = true
                }
            }
        }

        return changed ? String(scalars) : nil
    }

    // The trie walk's per-character rule: the modern form of an old-form kanji, else the hiragana
    // for a katakana, else nil. The walk itself enforces the has-a-kanji condition for katakana,
    // since one character can't know what word it's in.
    static func alternate(_ character: Character) -> Character? {
        if let modern = normalize(character) { return modern }
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, let hiragana = hiraganaScalar(for: scalar) else {
            return nil
        }
        return Character(hiragana)
    }

    // Whether the character is a kanji (CJK ideograph), the condition for katakana to stand in for
    // hiragana. Checks every scalar against the ideograph blocks.
    static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isKanji)
    }

    // CJK Unified Ideographs, Extension A, Compatibility Ideographs and the supplementary planes.
    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true
        default: return false
        }
    }

    // The hiragana for a full-width katakana scalar (ァ…ヶ sit 0x60 above ぁ…ゖ), nil for anything else.
    private static func hiraganaScalar(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        guard (0x30A1...0x30F6).contains(scalar.value) else { return nil }
        return Unicode.Scalar(scalar.value - 0x60)
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
