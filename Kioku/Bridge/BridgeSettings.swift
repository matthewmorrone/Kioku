import Foundation

// Centralizes storage keys and defaults for the local-network MCP bridge.
// Keys use the kioku.bridge prefix to avoid colliding with other settings.
enum BridgeSettings {
    static let enabledKey = "kioku.bridge.enabled"
    static let tokenKey = "kioku.bridge.token"
    static let portKey = "kioku.bridge.port"

    // Keep the default off the well-known 0..1023 range and out of common dev ports.
    static let defaultPort: Int = 47823
    static let minPort: Int = 1024
    static let maxPort: Int = 65535

    // Generates a URL-safe random bearer token. Used when the user taps "Regenerate"
    // and on first enable when no token has been provisioned yet.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            // Fall back to UUIDs if SecRandom fails so the bridge can still be provisioned;
            // both UUIDs combined are 32 hex chars of entropy which is acceptable for LAN auth.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Returns the persisted token, creating and saving one on first read so callers
    // never have to deal with a nil/empty token.
    static func currentOrProvisionedToken(userDefaults: UserDefaults = .standard) -> String {
        if let existing = userDefaults.string(forKey: tokenKey), existing.isEmpty == false {
            return existing
        }
        let token = makeToken()
        userDefaults.set(token, forKey: tokenKey)
        return token
    }

    // Reads the configured port, clamping to the allowed range and defaulting when unset.
    static func currentPort(userDefaults: UserDefaults = .standard) -> Int {
        let raw = userDefaults.object(forKey: portKey) as? Int ?? defaultPort
        return min(max(raw, minPort), maxPort)
    }
}
