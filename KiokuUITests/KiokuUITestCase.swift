import XCTest

// Shared steps for the UI tests: launching Kioku the way they need it, keeping evidence for a CI
// failure, and the moves several tests make (switch tabs, open the sample note, save its first
// word). Holds no tests itself.
//
// Every test in a run shares one simulator, so what one saves or resets the next one sees. The
// steps here therefore end in a state ("the word is saved") rather than assume where they start.
@MainActor
class KiokuUITestCase: XCTestCase {
    // The sample note every fresh install starts with, and the word at the start of its text.
    let sampleNoteTitle = "キャラメルと飴玉"
    let sampleWord = "キャラメル"

    // Launches Kioku with the repo's dictionary (Resources/dictionary.sqlite, fetched by
    // scripts/ensure_dictionary.sh), so a fresh simulator skips the download, and without tours.
    // Attaches the app's startup log when the test ends, pass or fail.
    func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let dictionary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/dictionary.sqlite")
        app.launchEnvironment["KIOKU_UITEST_DICTIONARY"] = dictionary.path
        app.launch()
        addTeardownBlock { Self.attachAppStartupLog() }
        // A cold first launch loads the dictionary before the UI settles, and on CI a blank system
        // overlay sometimes covers the app for its first ~30 s (the tab bar exists but has no hit
        // point). Wait until the tab bar takes taps rather than tapping into it.
        let notes = app.tabBars.buttons["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 120), "app never finished launching")
        if wait(for: notes, toMatch: "hittable == true", timeout: 90) == false { record(app, "tab bar never hittable") }
        return app
    }

    // Keeps a screenshot and the element tree with the result, so a CI failure can be read
    // without a simulator: what was on screen, and what the test could see of it.
    func record(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) — elements"
        tree.lifetime = .keepAlways
        add(tree)
    }

    // Attaches Kioku's startup-timing.log (StartupTimer's marks, and MainThreadStallWatch's stalls
    // in UI-test launches). The test runner and the app are both apps on the same simulator, so
    // the runner finds the log in its sibling app containers. Static, attaching through an
    // activity, so the teardown block that calls it captures nothing.
    private static func attachAppStartupLog() {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let attachment: XCTAttachment
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: containers.path)
            let logs = names
                .map { containers.appendingPathComponent($0).appendingPathComponent("Library/Caches/startup-timing.log") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if let log = logs.first {
                attachment = XCTAttachment(contentsOfFile: log)
                attachment.name = "app startup log"
            } else {
                attachment = XCTAttachment(string: "no startup-timing.log among \(names.count) containers in \(containers.path)")
                attachment.name = "app startup log missing"
            }
        } catch {
            attachment = XCTAttachment(string: "couldn't list \(containers.path): \(error)")
            attachment.name = "app startup log missing"
        }
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "App startup log") { $0.add(attachment) }
    }

    // Taps a tab until the tab bar shows it selected: a tap that lands while a sheet is still
    // animating away is dropped.
    func selectTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "\(name) tab missing")
        wait(for: tab, toMatch: "hittable == true", timeout: 30)
        var taps = 0
        while tab.isSelected == false && taps < 3 {
            tab.tap()
            wait(for: tab, toMatch: "isSelected == true", timeout: 5)
            taps += 1
        }
        XCTAssertTrue(tab.isSelected, "\(name) tab never selected")
    }

    // Waits for an element to satisfy a predicate; returns whether it did.
    @discardableResult
    func wait(for element: XCUIElement, toMatch predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = expectation(for: NSPredicate(format: predicate), evaluatedWith: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // Drags a sheet down by a point just above the given element in it, which dismisses it whether
    // or not its content scrolls.
    func dismissSheet(_ app: XCUIApplication, above element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -24))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 700)))
        wait(for: element, toMatch: "exists == false", timeout: 10)
    }

    // Opens the sample note from the Notes tab and waits for its text view.
    func openSampleNote(_ app: XCUIApplication) {
        selectTab(app, "Notes")
        let note = app.staticTexts[sampleNoteTitle].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "sample note not listed")
        note.tap()
        // The note's body comes first; other text views (the title) reuse the same view.
        let text = app.otherElements["readerText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "note didn't open in the reader")
    }

    // Opens the lookup sheet for the note's first word (キャラメル) and returns its save star. The
    // reader exposes each laid-out line as a static text; this taps inside the first line's first
    // word. The note segments once the dictionary has loaded, and until then a tap has no word
    // under it, so this retries until the sheet answers for キャラメル.
    func openLookupForFirstWord(_ app: XCUIApplication) -> XCUIElement {
        let firstLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "キャラメルと飴玉とが")).firstMatch
        XCTAssertTrue(firstLine.waitForExistence(timeout: 60), "note's first line not laid out")
        // The lookup sheet's star (its label says whether the word is saved), and the word it's for.
        let star = app.buttons["lookupSaveStar"].firstMatch
        let sheetWord = app.buttons["Speak \(sampleWord)"].firstMatch
        // キャラメル is the line's first five characters, about 20 points each.
        let offsets: [CGFloat] = [50, 30, 70]
        var attempt = 0
        while sheetWord.exists == false && attempt < offsets.count * 3 {
            let start = firstLine.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.6))
            start.withOffset(CGVector(dx: offsets[attempt % offsets.count], dy: 0)).tap()
            _ = sheetWord.waitForExistence(timeout: 5)
            attempt += 1
        }
        if sheetWord.exists == false { record(app, "no lookup sheet for \(sampleWord)") }
        XCTAssertTrue(sheetWord.exists, "lookup sheet for \(sampleWord) never appeared")
        XCTAssertTrue(star.exists, "lookup sheet has no save star")
        return star
    }

    // Taps the lookup sheet's star and waits for its label to flip to `expected`.
    func toggleStar(_ star: XCUIElement, expecting expected: String) {
        star.tap()
        XCTAssertTrue(wait(for: star, toMatch: "label == '\(expected)'", timeout: 5), "star didn't turn to \(expected)")
    }

    // Leaves the sample note's first word saved: opens the note, looks the word up, stars it if it
    // isn't starred, and closes the sheet.
    func ensureSampleWordSaved(_ app: XCUIApplication) {
        openSampleNote(app)
        let star = openLookupForFirstWord(app)
        if star.label == "Save" { toggleStar(star, expecting: "Unsave") }
        app.swipeDown()
        wait(for: star, toMatch: "exists == false", timeout: 10)
    }
}
