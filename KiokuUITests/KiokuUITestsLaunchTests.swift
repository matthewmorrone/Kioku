//
//  KiokuUITestsLaunchTests.swift
//  KiokuUITests
//
//  Created by Matthew Morrone on 2/24/26.
//

import XCTest

final class KiokuUITestsLaunchTests: XCTestCase {

    // Runs launch tests for each target configuration to validate startup behavior broadly.
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    // Sets launch-test execution defaults before each launch scenario.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    // Captures launch-screen evidence after app startup completes.
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
