import XCTest
@testable import Kioku

// Verifies old-form kanji (kyujitai and variant spellings) are modernized by KyujitaiNormalizer and,
// more importantly, that DictionaryTrie uses it: text written in an older orthography must match
// dictionary entries indexed in the modern form, with ranges and surfaces still in the text as written.
final class KyujitaiNormalizerTests: XCTestCase {

    // Reads the generated table back as (old, new) scalar pairs so property tests cover every entry.
    private func tablePairs() -> [(old: Unicode.Scalar, new: Unicode.Scalar)] {
        let scalars = Array(KyujitaiTable.flatPairs.unicodeScalars.filter { $0.properties.isWhitespace == false })
        var pairs: [(old: Unicode.Scalar, new: Unicode.Scalar)] = []
        var index = 0
        while index + 1 < scalars.count {
            pairs.append((old: scalars[index], new: scalars[index + 1]))
            index += 2
        }
        return pairs
    }

    // Builds a trie whose entries are indexed the way the real dictionary indexes them: modern spellings,
    // one word under both spellings, and one entry that only exists in the old form.
    private func makeTrie() -> DictionaryTrie {
        let trie = DictionaryTrie()
        trie.insert("残る", entryIDs: [10], partOfSpeech: 1)
        trie.insert("気づく", entryIDs: [20], partOfSpeech: 2)
        trie.insert("気づいた", entryIDs: [21], partOfSpeech: 2)
        trie.insert("電気", entryIDs: [30], partOfSpeech: 4)
        trie.insert("電氣", entryIDs: [31], partOfSpeech: 8)
        trie.insert("國", entryIDs: [40], partOfSpeech: 16)
        trie.insert("の", entryIDs: [50], partOfSpeech: 32)
        return trie
    }

    // Returns the substrings of `text` matched by a prefix scan at a character offset.
    private func matches(_ trie: DictionaryTrie, in text: String, at offset: Int = 0) -> [String] {
        let start = text.index(text.startIndex, offsetBy: offset)
        return trie.prefixMatches(in: text, startingAt: start).map { String(text[$0]) }
    }

    // Verifies the two forms from the reported note normalize, and modern text is reported as unchanged.
    func testNormalizeModernizesOldFormsAndLeavesModernTextAlone() {
        XCTAssertEqual(KyujitaiNormalizer.normalize("痛みが殘るよ"), "痛みが残るよ")
        XCTAssertEqual(KyujitaiNormalizer.normalize("氣づいた"), "気づいた")
        XCTAssertNil(KyujitaiNormalizer.normalize("痛みが残るよ"))
        XCTAssertNil(KyujitaiNormalizer.normalize("ひらがなとカタカナ"))
    }

    // Verifies old forms that map to several modern characters resolve to the Jouyou kanji, not the rarer variant.
    func testAmbiguousOldFormsResolveToTheJouyouKanji() {
        XCTAssertEqual(KyujitaiNormalizer.normalize("鹽"), "塩")
        XCTAssertEqual(KyujitaiNormalizer.normalize("莊"), "荘")
        XCTAssertEqual(KyujitaiNormalizer.normalize("畫"), "画")
        XCTAssertEqual(KyujitaiNormalizer.normalize("驅"), "駆")
    }

    // Regression: 賠 is its own character, not an old form of 陪; an earlier hand-typed table mapped it,
    // which would have turned 賠償 into 陪償.
    func testDistinctCharactersAreNotTreatedAsOldForms() {
        XCTAssertNil(KyujitaiNormalizer.normalize("賠償"))
        XCTAssertNil(KyujitaiNormalizer.normalize("陪審"))
    }

    // Property: modernizing is idempotent and never changes length, so a second pass is a no-op and
    // offsets into the original text stay valid, for every pair in the generated table.
    func testEveryTableEntryIsIdempotentAndLengthPreserving() {
        let pairs = tablePairs()
        XCTAssertGreaterThan(pairs.count, 300)
        for pair in pairs {
            let old = String(Character(pair.old))
            let modern = KyujitaiNormalizer.normalize(old)
            XCTAssertEqual(modern, String(Character(pair.new)), "\(old) should modernize to \(Character(pair.new))")
            XCTAssertEqual(modern?.utf16.count, old.utf16.count, "\(old) changes UTF-16 length")
            XCTAssertNil(modern.flatMap { KyujitaiNormalizer.normalize($0) }, "\(old) needs two passes")
        }
    }

    // Verifies a kanji carrying a variation selector (two scalars) is left alone rather than half-converted.
    func testCharacterWithCombiningScalarIsNotConverted() {
        let withSelector = Character("氣\u{FE00}")
        XCTAssertNil(KyujitaiNormalizer.normalize(withSelector))
        XCTAssertEqual(KyujitaiNormalizer.normalize(Character("氣")), "気")
    }

    // Verifies the trie matches old-form spellings of modern-indexed words through every lookup path.
    func testTrieResolvesOldFormSpellingsOfModernEntries() {
        let trie = makeTrie()
        XCTAssertTrue(trie.contains("殘る"))
        XCTAssertTrue(trie.contains("氣づいた"))
        XCTAssertFalse(trie.contains("殘る舞い"))
        XCTAssertEqual(trie.partOfSpeech(for: "殘る"), 1)
        XCTAssertEqual(trie.hitMeta(for: "氣づく")?.entryIDs, [20])
    }

    // Verifies prefix scans over old-form text return ranges of the original characters and the
    // original surface, resolving the modern entry's IDs.
    func testPrefixScansKeepTheTextAsWritten() {
        let trie = makeTrie()
        XCTAssertEqual(matches(trie, in: "痛みが殘るよ", at: 3), ["殘る"])
        XCTAssertEqual(matches(trie, in: "氣づいた"), ["氣づいた"])

        let text = "氣づいた"
        let hits = trie.prefixHits(in: text, startingAt: text.startIndex)
        XCTAssertEqual(hits.map(\.surface), ["氣づいた"])
        XCTAssertEqual(hits.first?.indices, [21])
        XCTAssertEqual(trie.prefixScan(in: "殘る", startingAt: "殘る".startIndex, maxLength: 8).scannedEnd, "殘る".endIndex)
    }

    // Verifies a word indexed under both spellings returns both entries for the old spelling, while
    // the modern spelling does not pull in the old-form entry.
    func testWordIndexedUnderBothSpellingsMergesEntriesOnlyForTheOldSpelling() {
        let trie = makeTrie()
        XCTAssertEqual(trie.hitMeta(for: "電氣")?.entryIDs, [30, 31])
        XCTAssertEqual(trie.hitMeta(for: "電気")?.entryIDs, [30])

        let text = "電氣"
        let hits = trie.prefixHits(in: text, startingAt: text.startIndex)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.indices, [30, 31])
        XCTAssertEqual(hits.first?.surface, "電氣")
    }

    // Verifies normalization only runs old -> modern: an entry that exists only in the old form still
    // matches as written, and its modern spelling stays a miss.
    func testOldFormOnlyEntriesStillMatchAsWrittenAndAreNotReversed() {
        let trie = makeTrie()
        XCTAssertTrue(trie.contains("國"))
        XCTAssertFalse(trie.contains("国"))
    }

    // Regression guard: ordinary text without old forms scans exactly as it did before normalization existed.
    func testTextWithoutOldFormsIsUnaffected() {
        let trie = makeTrie()
        XCTAssertEqual(matches(trie, in: "のの"), ["の"])
        XCTAssertTrue(matches(trie, in: "あいう").isEmpty)
        XCTAssertEqual(matches(trie, in: "残る"), ["残る"])
    }
}
