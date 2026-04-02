import Foundation

// Centralizes persisted settings and defaults for the lyric-alignment server integration.
enum LyricAlignmentSettings {
    static let baseURLKey = "kioku.settings.lyricAlignment.baseURL"
    static let pathKey = "kioku.settings.lyricAlignment.path"
    static let languageKey = "kioku.settings.lyricAlignment.language"

    static let defaultBaseURL = "http://192.168.0.215:8000"
    static let defaultPath = "/align"
    static let defaultLanguage = "ja"

    struct Configuration {
        let endpoint: URL
        let language: String
    }

    static func configuration(userDefaults: UserDefaults = .standard) throws -> Configuration {
        let baseURL = (userDefaults.string(forKey: baseURLKey) ?? defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (userDefaults.string(forKey: pathKey) ?? defaultPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = (userDefaults.string(forKey: languageKey) ?? defaultLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let resolvedBaseURL = URL(string: baseURL), resolvedBaseURL.scheme != nil else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Lyric Alignment Base URL is invalid. Check Settings."]
            )
        }

        var endpoint = resolvedBaseURL
        let pathComponents = path
            .split(separator: "/")
            .map(String.init)
            .filter { $0.isEmpty == false }

        for component in pathComponents {
            endpoint.appendPathComponent(component)
        }

        return Configuration(
            endpoint: endpoint,
            language: language.isEmpty ? defaultLanguage : language
        )
    }
}
