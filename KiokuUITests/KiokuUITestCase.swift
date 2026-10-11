import XCTest

// Shared steps for the UI tests: launching Kioku the way they need it, keeping evidence for a CI
// failure, and the moves several tests make (switch tabs, open the sample note, save its first
// word). Holds no tests itself.
//
// Every test in a run shares one simulator, so what one saves or resets the next one sees. The
// steps here therefore end in a state ("the word is saved") rather than assume where they start.
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
        addTeardownBlock { [weak self] in self?.attachAppStartupLog() }
        // A cold first launch loads the dictionary before the UI settles; wait for the tab bar
        // rather than tapping into a busy app.
        XCTAssertTrue(app.tabBars.buttons["Notes"].waitForExistence(timeout: 120), "app never finished launching")
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
    // the runner finds the log in its sibling app containers.
    private func attachAppStartupLog() {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let note: String
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: containers.path)
            let logs = names
                .map { containers.appendingPathComponent($0).appendingPathComponent("Library/Caches/startup-timing.log") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if let log = logs.first {
                let attachment = XCTAttachment(contentsOfFile: log)
                attachment.name = "app startup log"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            note = "no startup-timing.log among \(names.count) containers in \(containers.path)"
        } catch {
            note = "couldn't list \(containers.path): \(error)"
        }
        let attachment = XCTAttachment(string: note)
        attachment.name = "app startup log missing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Taps a tab until the tab bar shows it selected: a tap that lands while a sheet is still
    // animating away is dropped.
    func selectTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "\(name) tab missing")
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

    // Opens the sample note from the Notes tab and returns its text view, once it shows.
    func openSampleNote(_ app: XCUIApplication) -> XCUIElement {
        selectTab(app, "Notes")
        let note = app.staticTexts[sampleNoteTitle].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "sample note not listed")
        note.tap()
        // The note's body comes first; other text views (the title) reuse the same view.
        let text = app.otherElements["readerText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "note didn't open in the reader")
        return text
    }

    // Opens the lookup sheet for the note's first word and returns its save star. The note
    // segments once the dictionary has loaded; until then a tap has no word under it, so this
    // taps points across the first line (below its ruby) until the sheet answers.
    func openLookupForFirstWord(_ app: XCUIApplication, in text: XCUIElement) -> XCUIElement {
        // The lookup sheet's star; its label says whether the word is saved.
        let star = app.buttons["lookupSaveStar"].firstMatch
        let points = [(20, 28), (40, 28), (60, 40), (20, 50), (80, 50), (40, 70)]
        var attempt = 0
        while star.exists == false && attempt < points.count * 2 {
            let (x, y) = points[attempt % points.count]
            text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
            _ = star.waitForExistence(timeout: 5)
            attempt += 1
        }
        if star.exists == false { record(app, "no lookup sheet") }
        XCTAssertTrue(star.exists, "lookup sheet's save star never appeared")
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
        let text = openSampleNote(app)
        let star = openLookupForFirstWord(app, in: text)
        if star.label == "Save" { toggleStar(star, expecting: "Unsave") }
        app.swipeDown()
        wait(for: star, toMatch: "exists == false", timeout: 10)
    }
}
