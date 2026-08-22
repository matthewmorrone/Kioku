import XCTest
@testable import Kioku

// What the app is willing to accept from the on-device model when it rewrites quiz options. Every
// case here is a way a small model gets it wrong, and none of them may reach a question.
final class DistractorRefinementTests: XCTestCase {

    private func request(
        prompt: String = "食べる",
        correct: String = "to eat",
        accepted: [String] = ["to eat", "eat"],
        candidates: [String] = ["to drink", "to run", "book"],
        field: StudyField = .meaning
    ) -> DistractorRequest {
        DistractorRequest(
            prompt: prompt, correct: correct, acceptedAnswers: accepted,
            candidates: candidates, answerField: field
        )
    }

    // MARK: - Pool picks

    func testKeepsPicksInTheModelsOrder() {
        let refinement = DistractorRefinement(
            chosen: ["to run", "to drink"], poolIsTooShallow: false, invented: []
        )
        XCTAssertEqual(
            DistractorRefinementPolicy.acceptedPicks(refinement, request: request()),
            ["to run", "to drink"]
        )
    }

    // The model returns options it was never shown; they'd be unverifiable wrong answers.
    func testDropsPicksThatWereNeverOffered() {
        let refinement = DistractorRefinement(
            chosen: ["to swim", "to drink"], poolIsTooShallow: false, invented: []
        )
        XCTAssertEqual(
            DistractorRefinementPolicy.acceptedPicks(refinement, request: request()),
            ["to drink"]
        )
    }

    func testDropsRepeatedPicks() {
        let refinement = DistractorRefinement(
            chosen: ["to drink", "to drink", "to run"], poolIsTooShallow: false, invented: []
        )
        XCTAssertEqual(
            DistractorRefinementPolicy.acceptedPicks(refinement, request: request()),
            ["to drink", "to run"]
        )
    }

    // MARK: - Inventions

    func testAcceptsRealJapaneseWordsInTheAnswersScript() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["のむ", "はしる"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement,
            request: request(correct: "たべる", accepted: ["たべる"], candidates: ["ある"], field: .kana),
            alreadyChosen: [],
            isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["のむ", "はしる"])
    }

    // The model coins plausible-looking non-words; a learner can't tell those from real ones.
    func testRejectsInventedJapaneseWordsTheDictionaryDoesNotKnow() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["のむ", "ぬべる"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement,
            request: request(correct: "たべる", accepted: ["たべる"], candidates: ["ある"], field: .kana),
            alreadyChosen: [],
            isRealWord: { $0 == "のむ" }
        )
        XCTAssertEqual(accepted, ["のむ"])
    }

    // A kana question can't be answered with kanji, and vice versa.
    func testRejectsInventionsInTheWrongScript() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["飲む", "のむ"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement,
            request: request(correct: "たべる", accepted: ["たべる"], candidates: ["ある"], field: .kana),
            alreadyChosen: [],
            isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["のむ"])
    }

    func testRejectsJapaneseTextOfferedAsAnEnglishMeaning() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["飲む", "to sleep"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement, request: request(), alreadyChosen: [], isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["to sleep"])
    }

    // A second correct answer is the worst failure mode of the lot: the learner is marked wrong for
    // being right. Caught even when the model rephrases it.
    func testRejectsAnyAcceptedAnswerHoweverPhrased() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["Eat", "to eat", "to sleep"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement, request: request(), alreadyChosen: [], isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["to sleep"])
    }

    func testRejectsInventionsThatDuplicateWhatIsAlreadyOnOffer() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["to run", "to sleep", "to sleep"]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement, request: request(), alreadyChosen: ["to drink"], isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["to sleep"], "a pool candidate and a repeat are both already covered")
    }

    func testTrimsWhitespaceTheModelPadsItsAnswersWith() {
        let refinement = DistractorRefinement(
            chosen: [], poolIsTooShallow: true, invented: ["  to sleep  ", "   "]
        )
        let accepted = DistractorRefinementPolicy.acceptedInventions(
            refinement, request: request(), alreadyChosen: [], isRealWord: { _ in true }
        )
        XCTAssertEqual(accepted, ["to sleep"])
    }
}
