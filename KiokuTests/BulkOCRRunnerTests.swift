import XCTest
@testable import Kioku

// Pins bulk photo OCR: one result per photo in pick order, a bad photo costing only itself, and the
// notes and report derived from those results.
@MainActor
final class BulkOCRRunnerTests: XCTestCase {
    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func outcomes() -> [BulkOCROutcome] {
        let inputs: [BulkOCRInput] = [
            .image(Data("a".utf8)), .image(Data("blank".utf8)), .unreadable("could not load"),
            .image(Data("bad".utf8)), .image(Data("b".utf8)),
        ]
        return BulkOCRRunner.run(inputs: inputs) { data in
            switch String(decoding: data, as: UTF8.self) {
            case "a": return " 猫\n"
            case "blank": return "  "
            case "bad": throw Boom()
            default: return "犬"
            }
        }
    }

    func testEachPhotoGetsItsOwnOutcomeInOrder() {
        XCTAssertEqual(outcomes(), [.recognized("猫"), .noText, .failed("could not load"), .failed("boom"), .recognized("犬")])
    }

    func testNotesAreTitledByPhotoPosition() {
        let notes = BulkOCRRunner.notes(from: outcomes())
        XCTAssertEqual(notes.map(\.title), ["Photo 1", "Photo 5"])
        XCTAssertEqual(notes.map(\.content), ["猫", "犬"])
    }

    func testSummaryReportsEveryProblemPhoto() {
        XCTAssertEqual(
            BulkOCRRunner.summary(of: outcomes()),
            "Read 2 of 5 photos into notes.\nPhoto 2: no text found.\nPhoto 3: could not load\nPhoto 4: boom"
        )
    }
}
