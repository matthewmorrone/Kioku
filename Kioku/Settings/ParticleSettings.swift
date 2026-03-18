import Foundation

// Manages the persistent set of single-kana morphemes permitted as standalone segments in lattice paths.
// Uses comma-joined AppStorage so the SettingsView can bind directly without custom encoding.
enum ParticleSettings {
    static let storageKey = "kioku.particles.allowed"

    static let defaults: [String] = KanaData.defaultParticles.sorted()

    static let defaultRawValue: String = defaults.joined(separator: ",")

    // Returns the currently saved allowlist, falling back to defaults when the user has not customized it.
    static func allowed() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return Set(decodeList(from: raw))
    }

    // Decodes a comma-joined raw string into a sorted particle list.
    static func decodeList(from rawValue: String) -> [String] {
        let source = rawValue.isEmpty ? defaultRawValue : rawValue
        return source
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    // Encodes a particle list into a comma-joined raw string for AppStorage.
    static func encodeList(_ list: [String]) -> String {
        list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: ",")
    }

    // Removes persisted customization so allowed() returns defaults again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
