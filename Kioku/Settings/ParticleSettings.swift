import Foundation

// Manages the persistent set of single-kana morphemes permitted as standalone segments in lattice paths.
// Uses the same common_particles.json resource as Segmenter and SegmentListView so defaults stay in sync.
enum ParticleSettings {
    static let storageKey = "kioku.particles.allowed"

    // Loads the default particle list from the bundled resource.
    static let defaults: [String] = {
        guard
            let url = Bundle.main.url(forResource: "common_particles", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let particles = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return particles.sorted()
    }()

    // Returns the currently saved allowlist, falling back to defaults when the user has not customized it.
    static func allowed() -> Set<String> {
        guard
            let raw = UserDefaults.standard.string(forKey: storageKey),
            let data = raw.data(using: .utf8),
            let particles = try? JSONDecoder().decode([String].self, from: data)
        else {
            return Set(defaults)
        }
        return Set(particles)
    }

    // Persists the particle allowlist to UserDefaults.
    static func save(_ particles: Set<String>) {
        guard
            let data = try? JSONEncoder().encode(particles.sorted()),
            let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    // Removes persisted customization so allowed() returns defaults again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
