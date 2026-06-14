import XCTest
@testable import Kioku

// Pins the Keychain secret-storage contract: round-trip, overwrite, clear-on-empty,
// and the one-time migration that moves legacy UserDefaults secrets out of the plist.
final class KeychainStoreTests: XCTestCase {
    private let key = "kioku.tests.keychainStore"
    private let probeKey = "kioku.tests.keychainStore.probe"

    override func tearDownWithError() throws {
        KeychainStore.setString(nil, forKey: key)
        KeychainStore.setString(nil, forKey: probeKey)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // Skips when the Keychain can't be written. Unsigned CI test hosts run without a
    // keychain-access-group entitlement, so the Security framework rejects generic-password
    // writes with errSecMissingEntitlement and every assertion here would fail for an
    // environmental reason rather than a real regression. The contract these tests pin still
    // runs and passes on device and on a signed local host. A successful probe write (followed
    // by its own cleanup) is the cheapest reliable availability check.
    private func requireKeychainAvailable() throws {
        let wrote = KeychainStore.setString("probe", forKey: probeKey)
        KeychainStore.setString(nil, forKey: probeKey)
        try XCTSkipUnless(wrote, "Keychain unavailable (unsigned test host); skipping.")
    }

    // Values round-trip and a second write replaces the first.
    func testRoundTripAndOverwrite() throws {
        try requireKeychainAvailable()
        XCTAssertNil(KeychainStore.string(forKey: key))

        KeychainStore.setString("first", forKey: key)
        XCTAssertEqual(KeychainStore.string(forKey: key), "first")

        KeychainStore.setString("second", forKey: key)
        XCTAssertEqual(KeychainStore.string(forKey: key), "second")
    }

    // Storing nil or empty removes the item so cleared credentials leave nothing behind.
    func testClearOnNilOrEmpty() throws {
        try requireKeychainAvailable()
        KeychainStore.setString("secret", forKey: key)
        KeychainStore.setString("", forKey: key)
        XCTAssertNil(KeychainStore.string(forKey: key))

        KeychainStore.setString("secret", forKey: key)
        KeychainStore.setString(nil, forKey: key)
        XCTAssertNil(KeychainStore.string(forKey: key))
    }

    // A legacy UserDefaults value is returned, copied into the Keychain, and the
    // plaintext copy deleted — exactly once.
    func testMigratesLegacyUserDefaultsValue() throws {
        try requireKeychainAvailable()
        UserDefaults.standard.set("legacy-secret", forKey: key)

        let migrated = KeychainStore.string(forKey: key, migratingFromUserDefaultsKey: key)
        XCTAssertEqual(migrated, "legacy-secret")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
        XCTAssertEqual(KeychainStore.string(forKey: key), "legacy-secret")
    }
}
