//
//  KiokuUITests.swift
//  KiokuUITests
//
//  Created by Matthew Morrone on 2/24/26.
//

import XCTest

final class KiokuUITests: XCTestCase {

    // Prepares UI test execution settings before each test method runs.
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    // Releases UI test state after each test method completes.
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    // Verifies the app launches successfully in a baseline UI test flow.
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    // Measures launch-time performance to catch regressions in startup speed.
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
