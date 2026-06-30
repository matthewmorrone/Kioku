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

    // Internal stem-recovery labels are dropped, leaving only user-facing forms.
    func testRecoveryLabelsDropped() {
        XCTAssertEqual(InflectionFormNames.describe(["stemRecoveryForms", "teForms"]), "te-form")
    }

    // A chain of only internal labels yields "" so callers fall back to the lemma alone.
    func testAllInternalYieldsEmpty() {
        XCTAssertEqual(InflectionFormNames.describe(["stemRecoveryForms"]), "")
        XCTAssertEqual(InflectionFormNames.describe([]), "")
    }
}
