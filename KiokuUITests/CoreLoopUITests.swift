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

    // Keeps a screenshot and the element tree with the result, so a CI failure can be read
    // without a simulator: what was on screen, and what the test could see of it.
    private func record(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) — elements"
        tree.lifetime = .keepAlways
        add(tree)
    }

    // Opens the first sample note, taps its first word (キャラメル), saves it from the lookup sheet
    // and checks the Words tab lists it.
    func testLookUpSaveAndListAWord() {
        continueAfterFailure = false
        let app = launchApp()

        // A cold first launch builds the dictionary index before the UI settles; wait for the
        // tab bar rather than tapping into a busy app.
        XCTAssertTrue(app.tabBars.buttons["Notes"].waitForExistence(timeout: 120), "app never finished launching")
        app.tabBars.buttons["Notes"].tap()
        let note = app.staticTexts["キャラメルと飴玉"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "sample note not listed")
        note.tap()

        // The note's body comes first; other text views (the title) reuse the same view.
        let text = app.otherElements["readerText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "note didn't open in the reader")

        // The note segments once the dictionary has loaded; until then a tap has no word under
        // it. Tap points across the first line (below its ruby) until the lookup sheet answers.
        // The lookup sheet's star; its label says whether the word is saved.
        let save = app.buttons["lookupSaveStar"].firstMatch
        record(app, "reader opened")
        let points = [(20, 28), (40, 28), (60, 40), (20, 50), (80, 50), (40, 70)]
        var attempt = 0
        while save.exists == false && attempt < points.count * 2 {
            let (x, y) = points[attempt % points.count]
            text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
            _ = save.waitForExistence(timeout: 5)
            attempt += 1
        }
        if save.exists == false { record(app, "no lookup sheet") }
        XCTAssertTrue(save.exists, "lookup sheet's save star never appeared")
        XCTAssertEqual(save.label, "Save", "word was already saved")
        save.tap()
        let saved = NSPredicate(format: "label == %@", "Unsave")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: saved, evaluatedWith: save)], timeout: 5), .completed, "word didn't save")

        record(app, "saved")
        app.swipeDown()
        // A tab tap while the sheet is still animating away is dropped: wait for it to go, then
        // tap Words until the tab bar shows it selected.
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: save)], timeout: 10)
        let words = app.tabBars.buttons["Words"]
        var tabTaps = 0
        while words.isSelected == false && tabTaps < 3 {
            words.tap()
            _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: words)], timeout: 5)
            tabTaps += 1
        }
        record(app, "words tab")

        // Words opens on History; saved words are under Saved, chosen in the filter sheet.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "filter by Note or List")).firstMatch.tap()
        let savedSegment = app.segmentedControls.buttons["Saved"].firstMatch
        XCTAssertTrue(savedSegment.waitForExistence(timeout: 5), "filter sheet didn't open")
        savedSegment.tap()
        app.swipeDown()
        record(app, "saved list")
        XCTAssertTrue(app.staticTexts["キャラメル"].firstMatch.waitForExistence(timeout: 15), "saved word missing from Words")
    }
}
