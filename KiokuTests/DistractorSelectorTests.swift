import XCTest
@testable import Kioku

// The rules that decide which wrong answers a multiple-choice question offers: an option set the
// user can't shortcut by grammar or by okurigana.
final class DistractorSelectorTests: XCTestCase {

    // MARK: - Word class

    func testVerbTagsClassifyAsVerb() {
        XCTAssertEqual(WordClass.from(posTags: ["v1", "vt"]), .verb)
        XCTAssertEqual(WordClass.from(posTags: ["v5r", "vi"]), .verb)
    }

    // JMdict tags an adjectival noun both adj-na and n; the adjective reading is the useful one.
    func testAdjectiveWinsOverTheNounTagItShipsWith() {
        XCTAssertEqual(WordClass.from(posTags: ["adj-na", "n"]), .adjective)
        XCTAssertEqual(WordClass.from(posTags: ["adj-i"]), .adjective)
    }

    func testNounAndAdverbAndUnknownTags() {
        XCTAssertEqual(WordClass.from(posTags: ["n", "n-suf"]), .noun)
        XCTAssertEqual(WordClass.from(posTags: ["adv-to"]), .adverb)
        XCTAssertEqual(WordClass.from(posTags: ["int"]), .other)
        XCTAssertEqual(WordClass.from(posTags: [String]()), .other)
    }

    // MARK: - Okurigana

    func testSharedTrailingKanaCountsOnlyMatchingKana() {
        XCTAssertEqual(DistractorSelector.sharedTrailingKanaLength("食べる", "たべる"), 2)
        XCTAssertEqual(DistractorSelector.sharedTrailingKanaLength("たべる", "はしる"), 1)
        XCTAssertEqual(DistractorSelector.sharedTrailingKanaLength("たべる", "本"), 0)
        // Trailing kanji match but aren't okurigana, so they don't count as shared form.
        XCTAssertEqual(DistractorSelector.sharedTrailingKanaLength("日本", "西本"), 0)
    }

    // MARK: - Selection

    // The headline rule: a verb answer shouldn't be the only verb on offer.
    func testVerbAnswerDrawsVerbDistractorsAheadOfNouns() {
        let candidates = [
            DistractorCandidate(text: "book", wordClass: .noun),
            DistractorCandidate(text: "to run", wordClass: .verb),
            DistractorCandidate(text: "mountain", wordClass: .noun),
            DistractorCandidate(text: "to drink", wordClass: .verb),
            DistractorCandidate(text: "to write", wordClass: .verb),
        ]
        let chosen = DistractorSelector.choose(
            from: candidates,
            answer: DistractorCandidate(text: "to eat", wordClass: .verb),
            prompt: "食べる",
            count: 3
        )
        XCTAssertEqual(Set(chosen), ["to run", "to drink", "to write"])
    }

    // Class is a preference, not a filter: four options beat a grammatically tidy set of two.
    func testFallsBackToOtherClassesRatherThanReturningTooFewOptions() {
        let candidates = [
            DistractorCandidate(text: "book", wordClass: .noun),
            DistractorCandidate(text: "mountain", wordClass: .noun),
            DistractorCandidate(text: "to run", wordClass: .verb),
        ]
        let chosen = DistractorSelector.choose(
            from: candidates,
            answer: DistractorCandidate(text: "to eat", wordClass: .verb),
            prompt: "食べる",
            count: 3
        )
        XCTAssertEqual(chosen.count, 3, "all candidates are used rather than dropping to one option")
        XCTAssertEqual(chosen.first, "to run", "the matching class still leads")
    }

    // Asked 食べる → たべる, an option ending in べる can't be the giveaway if the others do too.
    func testMatchingOkuriganaOutranksAMismatchedEnding() {
        let candidates = [
            DistractorCandidate(text: "はしる", wordClass: .verb),
            DistractorCandidate(text: "しらべる", wordClass: .verb),
            DistractorCandidate(text: "くらべる", wordClass: .verb),
            DistractorCandidate(text: "のむ", wordClass: .verb),
            DistractorCandidate(text: "たすける", wordClass: .verb),
        ]
        let chosen = DistractorSelector.choose(
            from: candidates,
            answer: DistractorCandidate(text: "たべる", wordClass: .verb),
            prompt: "食べる",
            count: 3
        )
        XCTAssertEqual(Set(chosen.prefix(2)), ["しらべる", "くらべる"],
                       "the two options sharing べる come first")
        XCTAssertFalse(chosen.contains("のむ"), "an ending the prompt rules out is picked last")
    }

    // An English answer shares no kana with its prompt, so nothing is given away and only class
    // ranking applies — a same-class option must not lose to an accidental kana coincidence.
    func testEnglishAnswersRankOnClassAlone() {
        let candidates = [
            DistractorCandidate(text: "to run", wordClass: .verb),
            DistractorCandidate(text: "book", wordClass: .noun),
        ]
        let chosen = DistractorSelector.choose(
            from: candidates,
            answer: DistractorCandidate(text: "to eat", wordClass: .verb),
            prompt: "食べる",
            count: 1
        )
        XCTAssertEqual(chosen, ["to run"])
    }

    func testAsksForNoDistractorsReturnsNone() {
        let chosen = DistractorSelector.choose(
            from: [DistractorCandidate(text: "book", wordClass: .noun)],
            answer: DistractorCandidate(text: "to eat", wordClass: .verb),
            prompt: "食べる",
            count: 0
        )
        XCTAssertTrue(chosen.isEmpty)
    }
}
