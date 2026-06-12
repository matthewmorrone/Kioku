import XCTest
@testable import Kioku

// Pins the Keychain secret-storage contract: round-trip, overwrite, clear-on-empty,
// and the one-time migration that moves legacy UserDefaults secrets out of the plist.
final class KeychainStoreTests: XCTestCase {
    private let key = "kioku.tests.keychainStore"

    override func tearDownWithError() throws {
        KeychainStore.setString(nil, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // Values round-trip and a second write replaces the first.
    func testRoundTripAndOverwrite() {
        XCTAssertNil(KeychainStore.string(forKey: key))

        KeychainStore.setString("first", forKey: key)
        XCTAssertEqual(KeychainStore.string(forKey: key), "first")

        KeychainStore.setString("second", forKey: key)
        XCTAssertEqual(KeychainStore.string(forKey: key), "second")
    }

    // Storing nil or empty removes the item so cleared credentials leave nothing behind.
    func testClearOnNilOrEmpty() {
        KeychainStore.setString("secret", forKey: key)
        KeychainStore.setString("", forKey: key)
        XCTAssertNil(KeychainStore.string(forKey: key))

        KeychainStore.setString("secret", forKey: key)
        KeychainStore.setString(nil, forKey: key)
        XCTAssertNil(KeychainStore.string(forKey: key))
    }

    // A legacy UserDefaults value is returned, copied into the Keychain, and the
    // plaintext copy deleted — exactly once.
    func testMigratesLegacyUserDefaultsValue() {
        UserDefaults.standard.set("legacy-secret", forKey: key)

        let migrated = KeychainStore.string(forKey: key, migratingFromUserDefaultsKey: key)
        XCTAssertEqual(migrated, "legacy-secret")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
        XCTAssertEqual(KeychainStore.string(forKey: key), "legacy-secret")
    }
}
