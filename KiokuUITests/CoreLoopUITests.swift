import XCTest

// Drives Kioku's core loop through the real UI on a simulator: open a note, look a word up, save
// it, find it on the Words tab. The store-level tests (CoreLoopSmokeTests) cover the same loop
// without the UI; these catch what only the UI can break — a sheet that no longer opens, a tap that
// lands nowhere, a tab that stops listing what was saved.
final class CoreLoopUITests: XCTestCase {
    // Launches Kioku with the repo's dictionary (Resources/dictionary.sqlite, fetched by
    // scripts/ensure_dictionary.sh), so a fresh simulator skips the download, and without tours.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        let dictionary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/dictionary.sqlite")
        app.launchEnvironment["KIOKU_UITEST_DICTIONARY"] = dictionary.path
        app.launch()
        return app
    }

    // Opens the first sample note, taps its first word (キャラメル), saves it from the lookup sheet
    // and checks the Words tab lists it.
    func testLookUpSaveAndListAWord() {
        continueAfterFailure = false
        let app = launchApp()

        app.tabBars.buttons["Notes"].tap()
        let note = app.staticTexts["キャラメルと飴玉"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "sample note not listed")
        note.tap()

        // The note's body comes first; other text views (the title) reuse the same view.
        let text = app.otherElements["readerText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "note didn't open in the reader")

        // The note segments once the dictionary has loaded; until then a tap has no word under
        // it. Tap the first word (top-left, below its ruby) until the lookup sheet answers.
        // The lookup sheet's star; its label says whether the word is saved.
        let save = app.buttons["lookupSaveStar"].firstMatch
        let firstWord = text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 30))
        var attempts = 0
        while save.exists == false && attempts < 10 {
            firstWord.tap()
            _ = save.waitForExistence(timeout: 6)
            attempts += 1
        }
        XCTAssertTrue(save.exists, "lookup sheet's save star never appeared")
        XCTAssertEqual(save.label, "Save", "word was already saved")
        save.tap()
        let saved = NSPredicate(format: "label == %@", "Unsave")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: saved, evaluatedWith: save)], timeout: 5), .completed, "word didn't save")

        app.swipeDown()
        app.tabBars.buttons["Words"].tap()
        XCTAssertTrue(app.staticTexts["キャラメル"].firstMatch.waitForExistence(timeout: 15), "saved word missing from Words")
    }
}
