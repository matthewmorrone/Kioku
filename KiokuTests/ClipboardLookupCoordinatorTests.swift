import XCTest
@testable import Kioku

// Verifies the auto-detect toggle gates ClipboardLookupCoordinator.
// We don't mock UIPasteboard here — the test instead pins the contract that
// the coordinator reads from the injected UserDefaults so the toggle wires up
// end-to-end, and that the default value is unchanged from the prior implicit
// behavior (always on).
@MainActor
final class ClipboardLookupCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Per-test suite so values can't leak across cases (and so the
        // production .standard defaults are never touched).
        suiteName = "kioku-clipboard-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // When the toggle is absent, the coordinator must use the documented
    // default (on) so existing users see no behavior change after upgrade.
    func testDefaultsToAutoDetectEnabled() {
        XCTAssertEqual(ClipboardSettings.defaultAutoDetect, true)
        XCTAssertNil(defaults.object(forKey: ClipboardSettings.autoDetectKey))

        let coordinator = ClipboardLookupCoordinator(defaults: defaults)
        // Indirect: a disabled coordinator can never reach .hasPendingClipboard
        // = true via checkClipboard(); an enabled one would (subject to
        // pasteboard contents). We just call once and confirm it doesn't crash
        // or assert against the global state — the deeper gating is exercised
        // by testDisabledShortCircuits below.
        coordinator.checkClipboard()
    }

    // When the toggle is off, checkClipboard() short-circuits before any
    // pasteboard read — hasPendingClipboard never flips.
    func testDisabledShortCircuits() {
        defaults.set(false, forKey: ClipboardSettings.autoDetectKey)

        let coordinator = ClipboardLookupCoordinator(defaults: defaults)
        // Even after multiple calls (the production path runs on every focus),
        // the published flag remains its initial value.
        for _ in 0..<5 {
            coordinator.checkClipboard()
        }
        XCTAssertFalse(coordinator.hasPendingClipboard)
        XCTAssertNil(coordinator.consumeClipboard())
    }

    // Explicit-true behaves the same as the default (covers users who toggled
    // on then off then on — the key is now present, not absent).
    func testExplicitTrueAllowsCheck() {
        defaults.set(true, forKey: ClipboardSettings.autoDetectKey)

        let coordinator = ClipboardLookupCoordinator(defaults: defaults)
        // Just exercise the path; we don't assert on hasPendingClipboard
        // because that depends on whatever the test runner's pasteboard
        // currently contains (and we don't want to mutate the system one).
        coordinator.checkClipboard()
    }

    // dismiss() is independent of the toggle — should always clear state.
    func testDismissClearsRegardlessOfToggle() {
        defaults.set(false, forKey: ClipboardSettings.autoDetectKey)
        let coordinator = ClipboardLookupCoordinator(defaults: defaults)

        coordinator.dismiss()
        XCTAssertFalse(coordinator.hasPendingClipboard)
        XCTAssertNil(coordinator.consumeClipboard())
    }
}
