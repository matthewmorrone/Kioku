import XCTest
@testable import Kioku

// Pins the deinflection-chain → human-readable form mapping used in the lookup header.
final class InflectionFormNamesTests: XCTestCase {
    // A single known form maps to its display name.
    func testSingleForm() {
        XCTAssertEqual(InflectionFormNames.describe(["teForms"]), "te-form")
        XCTAssertEqual(InflectionFormNames.describe(["politeForms"]), "polite")
    }

    // Multiple forms join in chain order with " · ".
    func testChainJoins() {
        XCTAssertEqual(InflectionFormNames.describe(["politeForms", "pastForms"]), "polite · past")
    }

    // Negative forms map correctly (regression guard: the plain-negative rule used to live in
    // the progressiveForms catch-all and mislabeled as "progressive").
    func testNegativeForms() {
        XCTAssertEqual(InflectionFormNames.describe(["negativeForms"]), "negative")
        XCTAssertEqual(InflectionFormNames.describe(["negativeForms", "potentialForms"]), "negative · potential")
        XCTAssertEqual(InflectionFormNames.describe(["negativePastForms"]), "negative past")
    }

    // Internal stem-recovery labels are dropped, leaving only user-facing forms.
    func testRecoveryLabelsDropped() {
        XCTAssertEqual(InflectionFormNames.describe(["stemRecoveryForms", "teForms"]), "te-form")
    }

    // A chain of only internal labels yields "" so callers fall back to the lemma alone.
    func testAllInternalYieldsEmpty() {
        XCTAssertEqual(InflectionFormNames.describe(["stemRecoveryForms"]), "")
        XCTAssertEqual(InflectionFormNames.describe([]), "")
    }

    // The meaning hint merges common combinations idiomatically and joins the rest.
    func testMeaningMergesAndJoins() {
        XCTAssertEqual(InflectionFormNames.meaning(["negativeForms", "potentialForms"]), "can't ~")
        XCTAssertEqual(InflectionFormNames.meaning(["potentialForms"]), "can ~")
        XCTAssertEqual(InflectionFormNames.meaning(["desireForms", "pastForms"]), "want to ~ · did ~ (past)")
    }

    // Structural-only chains have no meaning hint.
    func testMeaningEmptyForStructuralOnly() {
        XCTAssertEqual(InflectionFormNames.meaning(["irregularForms"]), "")
        XCTAssertEqual(InflectionFormNames.meaning([]), "")
    }
}
