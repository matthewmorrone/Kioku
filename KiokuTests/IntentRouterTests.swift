import XCTest
@testable import Kioku

// Pins the intent hand-off: a request is performed once, and each intent raises the request the
// app shell expects.
@MainActor
final class IntentRouterTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        IntentRouter.shared.pending = nil
    }

    func testConsumeReturnsRequestOnce() {
        IntentRouter.shared.pending = .lookUp("猫")
        XCTAssertEqual(IntentRouter.shared.consume(), .lookUp("猫"))
        XCTAssertNil(IntentRouter.shared.consume())
    }

    func testReviewModeMapsToLearnPage() {
        XCTAssertEqual(ReviewMode.flashcards.learnPage, .flashcards)
        XCTAssertEqual(ReviewMode.multipleChoice.learnPage, .multipleChoice)
    }

    func testLookUpWordIntentRaisesTrimmedLookup() async throws {
        var intent = LookUpWordIntent()
        intent.word = "  犬 "
        _ = try await intent.perform()
        XCTAssertEqual(IntentRouter.shared.consume(), .lookUp("犬"))
    }

    func testCreateNoteIntentRejectsBlankText() async {
        var intent = CreateNoteIntent()
        intent.text = "   \n"
        do {
            _ = try await intent.perform()
            XCTFail("blank text should throw")
        } catch {
            XCTAssertNil(IntentRouter.shared.consume())
        }
    }

    func testStartReviewIntentRaisesChosenPage() async throws {
        var intent = StartReviewIntent()
        intent.mode = .multipleChoice
        _ = try await intent.perform()
        XCTAssertEqual(IntentRouter.shared.consume(), .startReview(.multipleChoice))
    }
}
