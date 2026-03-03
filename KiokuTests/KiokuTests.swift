//
//  KiokuTests.swift
//  KiokuTests
//
//  Created by Matthew Morrone on 2/24/26.
//

import Testing
import Kioku

struct KiokuTests {

    // Provides a placeholder test case for future unit coverage.
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    // Verifies LookupMode exposes explicit kanji matching policy.
    @Test func lookupModeKanjiPolicy() async throws {
        #expect(LookupMode.kanaOnly.matchKanji == false)
        #expect(LookupMode.kanjiAndKana.matchKanji == true)
    }

}
