import Foundation

// Centralizes persisted settings and defaults for the lyric-alignment server integration.
enum LyricAlignmentSettings {
    static let endpointKey = "kioku.settings.lyricAlignment.endpoint"

    static let defaultEndpoint = "http://192.168.0.215:8000/align"

    struct Configuration {
        let endpoint: URL
    }

    // Reads the user's alignment server settings and validates the URL, throwing a descriptive error when invalid.
    static func configuration(userDefaults: UserDefaults = .standard) throws -> Configuration {
        let endpointString = (userDefaults.string(forKey: endpointKey) ?? defaultEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpointURL = URL(string: endpointString), endpointURL.scheme != nil else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Lyric Alignment endpoint URL is invalid. Check Settings."]
            )
        }

        return Configuration(endpoint: endpointURL)
    }
}
