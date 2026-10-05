import Foundation

// How custom words are identified: by headword (first kanji, else first kana), and for new words by
// a stable negative ent_seq derived from it. Shared by the store, the applier and the codec so all
// three agree.
nonisolated enum CustomWordIdentity {
    // Below every extras.json ent_seq the builder derives (-100M to -1B) so the two can't collide.
    static let newWordEntSeqBase: Int64 = -10_000_000_000

    // The word's headword: its first kanji form, or its first kana form for a kana-only word.
    static func headword(of word: CustomWord) -> String {
        word.kanji.first ?? word.kana.first ?? ""
    }

    // A stable ent_seq for a new word with this headword (FNV-1a), assigned once when the word is
    // first stored and kept through later edits.
    static func entSeq(forHeadword headword: String) -> Int64 {
        var hash: UInt32 = 2_166_136_261
        for byte in headword.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return newWordEntSeqBase - Int64(hash)
    }
}
