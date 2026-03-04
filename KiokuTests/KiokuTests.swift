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

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func readEditorUsesTextKit2() async throws {
        let textView = await ReadEditorTextViewFactory.makeTextView()
        #expect(textView.textLayoutManager != nil)
    }

}
