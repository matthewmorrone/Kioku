import Foundation

// User-editable denylist of surfaces that segmentation should *deprioritize*.
//
// Some short surfaces exist as standalone entries (のか, のす, …) and, on raw node-cost arithmetic
// (or raw length, in greedy), outrank the compositional parse they should lose to — e.g. のか
// beating の + か. Rather than scatter `if surface == "のか"` comparisons through the scoring
// algorithm, the *strings* live here as data and the algorithm only asks `contains(_:)`.
//
// The list is now persisted in UserDefaults and editable from Settings (the same chip editor as
// the particle allowlist), seeded with the defaults below — so new breakers can be added from the
// app without a code change + rebuild. Encoding mirrors ParticleSettings (comma-joined) so the
// SettingsView binds the same way.
//
// The demotion is intentionally *soft*. It is consulted in two places, one per engine:
//   • Local longest-match  — Segmenter.compareEdgePriority sinks a demoted candidate below every
//     non-demoted candidate that starts at the same position (still chosen if it's the only one).
//   • Global longest-match — SegmenterScoring.edgeCost adds costDemotedSurfacePenalty to the node
//     cost. A demoted surface can still win if no cheaper global path exists.
nonisolated enum SegmentationDemotions {
    static let storageKey = "kioku.segmenter.demotions"

    // Default breakers, seeded into the editor. Match is on the raw detected *surface*, not the lemma.
    static let defaults: [String] = [
        "のか",   // particle cluster の + か; spurious as a single token
        "のす",   // spurious; should not absorb の
        "のこ",   // spurious; should not absorb の
        "はも",   // spurious; should not fuse は + も
        "があ",   // spurious; should not fuse が + あ
        "のま",
        "なの",
        "がす",
        "には",
        "にも",
        "よね",
        "しつ",
        "中二",
        "はと",
        "か弱い",
        "ような",
        "もし",
        "もした",  // rare 燃す past; almost always も + した (stem + emphatic も + した)
        "その物",  // spurious fusion; should be その + 物
    ]

    static let defaultRawValue: String = defaults.joined(separator: ",")

    // Decodes a comma-joined raw string into a list; empty falls back to defaults (matches ParticleSettings).
    static func decodeList(from rawValue: String) -> [String] {
        let source = rawValue.isEmpty ? defaultRawValue : rawValue
        return source
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    // Encodes a list into a comma-joined raw string for AppStorage.
    static func encodeList(_ list: [String]) -> String {
        list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: ",")
    }

    // Removes persisted customization so the list returns to defaults.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // Thread-safe cache. contains() runs per-edge during scoring, so re-decoding the comma string on
    // every call would be wasteful — instead read the (in-memory) raw value and only rebuild the Set
    // when it actually changes. The lock guards the cache across the segmenter's worker threads.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedRaw: String?
    nonisolated(unsafe) private static var cachedSet: Set<String> = []

    // Returns the current denylist as a set, decoding from UserDefaults only when the raw value changed.
    static func surfaces() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if raw != cachedRaw {
            cachedRaw = raw
            cachedSet = Set(decodeList(from: raw))
        }
        return cachedSet
    }

    // O(1) membership test used by both segmentation engines.
    static func contains(_ surface: String) -> Bool {
        surfaces().contains(surface)
    }
}
