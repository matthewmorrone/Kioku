//
//  KiokuTests.swift
//  KiokuTests
//
//  Created by Matthew Morrone on 2/24/26.
//

import Testing
import UIKit
@testable import Kioku

struct KiokuTests {

    // Provides a placeholder test case for future unit coverage.
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    // Guards the TextKit 2 invariant used by rich text rendering components.
    @Test func readEditorUsesTextKit2() async throws {
        let textView = TextViewFactory.makeTextView()
        #expect(textView.textLayoutManager != nil)
    }

}
