import XCTest

// Drives Kioku's core loop through the real UI on a simulator: look a word up in a note and save
// it, study it, and carry everything through a backup. The store-level tests (CoreLoopSmokeTests)
// cover the same loop without the UI; these catch what only the UI can break — a sheet that no
// longer opens, a tap that lands nowhere, a tab that stops listing what was saved.
//
// XCTest runs a class's tests in name order, and the names keep that order meaningful: the backup
// test erases everything before restoring it, so it runs last, where a failure halfway can't take
// the other tests' sample note with it.
final class CoreLoopUITests: KiokuUITestCase {
    // Opens the sample note, taps its first word (キャラメル), saves it from the lookup sheet
    // and checks the Words tab lists it under Saved.
    func testLookUpSaveAndListAWord() {
        let app = launchApp()
        openSampleNote(app)
        record(app, "reader opened")

        let star = openLookupForFirstWord(app)
        // An earlier test in the run may have saved it already; start from unsaved.
        if star.label == "Unsave" { toggleStar(star, expecting: "Save") }
        toggleStar(star, expecting: "Unsave")
        record(app, "saved")
        app.swipeDown()
        wait(for: star, toMatch: "exists == false", timeout: 10)

        selectTab(app, "Words")
        record(app, "words tab")
        showSavedWords(app)
        record(app, "saved list")
        XCTAssertTrue(app.staticTexts[sampleWord].firstMatch.waitForExistence(timeout: 15), "saved word missing from Words")
    }

    // Saves a word, starts Flashcards from the Learn tab and grades every card Know until the
    // session completes, which records each grade in the word's review stats.
    func testGradeFlashcardsUntilTheSessionCompletes() {
        let app = launchApp()
        ensureSampleWordSaved(app)

        selectTab(app, "Learn")
        let start = app.buttons["Start Flashcards"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "Flashcards start screen missing")
        record(app, "flashcards home")
        XCTAssertTrue(wait(for: start, toMatch: "isEnabled == true", timeout: 15), "Start Flashcards stays disabled with a saved word")
        start.tap()

        let know = app.buttons["Know"].firstMatch
        XCTAssertTrue(know.waitForExistence(timeout: 30), "session didn't start")
        record(app, "first card")
        let complete = app.staticTexts["Session complete"].firstMatch
        var graded = 0
        while complete.exists == false && know.exists && graded < 20 {
            know.tap()
            graded += 1
            _ = complete.waitForExistence(timeout: 2)
        }
        record(app, "session end")
        XCTAssertTrue(complete.exists, "session never completed after \(graded) Know grades")
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\(graded) correct")).firstMatch
        XCTAssertTrue(summary.exists, "session summary doesn't count \(graded) correct")
    }

    // Exports a backup, erases everything with Reset, then imports the backup and checks the
    // sample note is back: the full export → validate → replace-all round trip, through the
    // system file picker.
    func testRoundTripABackupThroughResetAndImport() {
        let app = launchApp()
        selectTab(app, "Settings")

        // Export: Kioku stages the backup, the system exporter saves it.
        tapSettingsRow(app, "Export")
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Move", "Done"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 30), "file exporter didn't open")
        record(app, "exporter")
        save.tap()
        // Saving over an earlier run's file asks first.
        let replace = app.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 3) { replace.tap() }
        acknowledgeAlert(app, titled: "Export Complete")

        // Reset, and confirm the note is gone.
        tapSettingsRow(app, "Reset")
        let confirmReset = app.alerts.buttons["Reset"].firstMatch
        XCTAssertTrue(confirmReset.waitForExistence(timeout: 10), "reset confirmation didn't appear")
        confirmReset.tap()
        acknowledgeAlert(app, titled: "Reset Complete")
        selectTab(app, "Notes")
        XCTAssertFalse(app.staticTexts[sampleNoteTitle].firstMatch.waitForExistence(timeout: 3), "reset left the sample note")

        // Import the file just exported, and confirm the replace.
        selectTab(app, "Settings")
        tapSettingsRow(app, "Import")
        // The file's cell; a tap on its name label alone doesn't open it.
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "kioku-export")).firstMatch
        findInImporter(app, file)
        record(app, "importer")
        file.tap()
        let confirmImport = app.alerts.buttons["Import"].firstMatch
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 15), "import confirmation didn't appear")
        confirmImport.tap()
        acknowledgeAlert(app, titled: "Import Complete")

        selectTab(app, "Notes")
        XCTAssertTrue(app.staticTexts[sampleNoteTitle].firstMatch.waitForExistence(timeout: 15), "sample note not restored")
    }

    // Words opens on History; saved words are under Saved, chosen in the filter sheet.
    private func showSavedWords(_ app: XCUIApplication) {
        let filter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "filter by Note or List")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 15), "Words filter button missing")
        filter.tap()
        let savedSegment = app.segmentedControls.buttons["Saved"].firstMatch
        XCTAssertTrue(savedSegment.waitForExistence(timeout: 10), "filter sheet didn't open")
        savedSegment.tap()
        dismissSheet(app, above: app.segmentedControls.firstMatch)
    }

    // The importer opens on Recents, empty on a fresh simulator; the export went to On My iPhone,
    // reached through Browse. Steps there until the file shows.
    private func findInImporter(_ app: XCUIApplication, _ file: XCUIElement) {
        let steps = [app.buttons["Browse"].firstMatch, app.staticTexts["On My iPhone"].firstMatch]
        var step = 0
        while file.waitForExistence(timeout: 10) == false && step < steps.count {
            if steps[step].exists { steps[step].tap() }
            step += 1
        }
        if file.exists == false { record(app, "importer without the file") }
        XCTAssertTrue(file.exists, "exported file not offered by the importer")
    }

    // Taps one of Settings' rows, scrolling down to it first when it's below the fold.
    private func tapSettingsRow(_ app: XCUIApplication, _ label: String) {
        let row = app.buttons[label].firstMatch
        var swipes = 0
        while (row.exists && row.isHittable) == false && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "Settings row \(label) not found")
        row.tap()
    }

    // Waits for the alert with this title and closes it with OK.
    private func acknowledgeAlert(_ app: XCUIApplication, titled title: String) {
        let alert = app.alerts[title].firstMatch
        if alert.waitForExistence(timeout: 30) == false { record(app, "no \(title) alert") }
        XCTAssertTrue(alert.exists, "\(title) alert didn't appear")
        alert.buttons["OK"].tap()
        wait(for: alert, toMatch: "exists == false", timeout: 10)
    }
}
