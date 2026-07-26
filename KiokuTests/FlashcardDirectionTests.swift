import XCTest
@testable import Kioku

// Characterizes FlashcardDirection.resolved(seed:) — in particular that .mixed only ever
// randomizes between the JP/English pair, never into kanjiToKana/kanaToKanji, so existing "Mixed"
// sessions keep behaving exactly as they did before kanjiToKana/kanaToKanji were added.
final class FlashcardDirectionTests: XCTestCase {

    func testFixedCasesResolveToThemselves() {
        XCTAssertEqual(FlashcardDirection.japaneseToEnglish.resolved(seed: 1), .japaneseToEnglish)
        XCTAssertEqual(FlashcardDirection.englishToJapanese.resolved(seed: 1), .englishToJapanese)
        XCTAssertEqual(FlashcardDirection.kanjiToKana.resolved(seed: 1), .kanjiToKana)
        XCTAssertEqual(FlashcardDirection.kanaToKanji.resolved(seed: 1), .kanaToKanji)
    }

    // .mixed only ever resolves to japaneseToEnglish or englishToJapanese — never the two new
    // script-only directions, which aren't part of what "Mixed" has ever meant.
    func testMixedOnlyResolvesToJapaneseEnglishPair() {
        let allowed: Set<FlashcardDirection> = [.japaneseToEnglish, .englishToJapanese]
        for seed in Int64(-20)...20 {
            let resolved = FlashcardDirection.mixed.resolved(seed: seed)
            XCTAssertTrue(allowed.contains(resolved), "seed \(seed) resolved to \(resolved)")
        }
    }

    func testMixedIsDeterministicPerSeed() {
        let first = FlashcardDirection.mixed.resolved(seed: 42)
        let second = FlashcardDirection.mixed.resolved(seed: 42)
        XCTAssertEqual(first, second)
    }

    // Even-numbered seeds resolve to japaneseToEnglish, odd to englishToJapanese — pinning the
    // exact split (not just "it's deterministic") since FlashcardsView.questionDirection(for:)
    // depends on this matching what FlashcardCard actually displayed.
    func testMixedSplitsByParity() {
        XCTAssertEqual(FlashcardDirection.mixed.resolved(seed: 0), .japaneseToEnglish)
        XCTAssertEqual(FlashcardDirection.mixed.resolved(seed: 1), .englishToJapanese)
        XCTAssertEqual(FlashcardDirection.mixed.resolved(seed: 2), .japaneseToEnglish)
    }
}
