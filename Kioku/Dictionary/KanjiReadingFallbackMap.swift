import Foundation

// Single-kanji → preferred hiragana reading, derived once from KANJIDIC2 at resource-load time.
// This is the last-resort furigana source: when no dictionary word or lemma reading resolves for
// a kanji-bearing segment (e.g. 眩 in the appearance form 眩しげ, which doesn't deinflect to its
// base adjective 眩しい), the resolver paints each kanji's standalone reading so the reader always
// sees *some* furigana over a kanji rather than a bare, un-annotated character.
//
// Reference-type wrapper, mirroring SurfaceReadingDataMap, so SwiftUI compares a single pointer
// instead of diffing the ~13k entries. Built once on a background thread and never mutated after.
// @unchecked Sendable: deeply immutable (a single `let data` set at init, no mutators), so it is safe
// to share across threads — e.g. captured by the subtitle importer's detached furigana-precompute task.
nonisolated final class KanjiReadingFallbackMap: Equatable, @unchecked Sendable {
    let data: [Character: String]

    // Creates an empty map for initial state before resources are loaded (and for tests/previews,
    // where the empty map disables the fallback so existing reading expectations are unaffected).
    init() {
        data = [:]
    }

    // Wraps a fully populated map produced by fetchKanjiReadingFallbackMap().
    init(_ data: [Character: String]) {
        self.data = data
    }

    var isEmpty: Bool {
        data.isEmpty
    }

    // Identity-based equality so SwiftUI skips diffing the dictionary contents.
    static func == (lhs: KanjiReadingFallbackMap, rhs: KanjiReadingFallbackMap) -> Bool {
        lhs === rhs
    }

    // Subscript passthrough for ergonomic per-character access.
    subscript(kanji: Character) -> String? {
        data[kanji]
    }
}
