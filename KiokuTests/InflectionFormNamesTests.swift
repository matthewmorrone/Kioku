import XCTest
@testable import Kioku

// Pins the deinflection-chain → human-readable form mapping used in the lookup header.
//
// Chain labels here are the NORMALIZED form InflectionFormNames.describe(_:) actually
// keys on (see that file's header comment) — Deinflector.normalizedRuleLabel strips the raw
// deinflection.json group name's "Forms" suffix and splits camelCase into lowercase
// space-separated words ("negativePastForms" -> "negative past") before this table ever sees it.
final class InflectionFormNamesTests: XCTestCase {
    // A single known form maps to its display name.
    func testSingleForm() {
        XCTAssertEqual(InflectionFormNames.describe(["te"]), "te-form")
        XCTAssertEqual(InflectionFormNames.describe(["polite"]), "polite")
    }

    // Multiple forms join in chain order with " · ".
    func testChainJoins() {
        XCTAssertEqual(InflectionFormNames.describe(["polite", "past"]), "polite · past")
    }

    // Negative forms map correctly (regression guard: the plain-negative rule used to live in
    // the progressiveForms catch-all and mislabeled as "progressive").
    func testNegativeForms() {
        XCTAssertEqual(InflectionFormNames.describe(["negative"]), "negative")
        XCTAssertEqual(InflectionFormNames.describe(["negative", "potential"]), "negative · potential")
        XCTAssertEqual(InflectionFormNames.describe(["negative past"]), "negative past")
    }

    // Internal stem-recovery labels are dropped, leaving only user-facing forms.
    func testRecoveryLabelsDropped() {
        XCTAssertEqual(InflectionFormNames.describe(["stem recovery", "te"]), "te-form")
    }

    // A chain of only internal labels yields "" so callers fall back to the lemma alone.
    func testAllInternalYieldsEmpty() {
        XCTAssertEqual(InflectionFormNames.describe(["stem recovery"]), "")
        XCTAssertEqual(InflectionFormNames.describe([]), "")
    }
}
