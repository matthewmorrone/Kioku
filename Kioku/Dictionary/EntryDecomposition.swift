import Foundation

// One piece of a multi-word headword — the 大人, the に or the なる of 大人になる.
//
// Harvested at build time with MeCab (Resources/generate_db.py's import_entry_decomposition),
// because JMdict carries no compositional field: an expression entry has a POS of "exp" and its
// glosses, and nothing that says what it is built from.
public struct EntryDecompositionPiece: Equatable, Identifiable {
    // Position within the headword, 0-based — also this piece's identity within one decomposition.
    public let orderIndex: Int
    // The slice of the headword as written.
    public let piece: String
    // The dictionary form, when it differs from the piece as written (食べ → 食べる, し → する).
    // nil when the piece is already its own dictionary form. This is what a tap looks up: 食べ
    // alone is not a headword.
    public let lemma: String?
    // MeCab's coarse part of speech (名詞, 助詞, 動詞 …). Drives whether a piece is worth offering
    // as a tap target — a bare case particle has an entry, but opening it teaches nothing.
    public let partOfSpeech: String?

    public var id: Int { orderIndex }

    // The surface to look this piece up by, preferring the dictionary form when one was recorded.
    public var lookupSurface: String { lemma ?? piece }

    // Whether this piece is worth making tappable. Case and sentence-final particles resolve to
    // real entries, so filtering has to be on part of speech rather than on lookup success.
    public var isFunctional: Bool {
        guard let partOfSpeech else { return false }
        return partOfSpeech == "助詞" || partOfSpeech == "助動詞" || partOfSpeech == "記号"
    }

    public init(orderIndex: Int, piece: String, lemma: String?, partOfSpeech: String?) {
        // Stores one harvested piece of a headword's decomposition.
        self.orderIndex = orderIndex
        self.piece = piece
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
    }
}
