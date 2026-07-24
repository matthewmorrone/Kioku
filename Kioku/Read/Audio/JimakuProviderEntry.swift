import Foundation

// One matched show from Jimaku's `/entries/search` response (only the fields JimakuProvider uses).
// nonisolated because JimakuProvider is a plain `actor` (not @MainActor) and reads `displayName`
// synchronously from its own isolation domain — without this, the module's default MainActor
// isolation would apply to this now-top-level type and make that access a cross-actor error.
nonisolated struct JimakuProviderEntry: Decodable {
    let id: Int64
    let name: String
    let englishName: String?
    // Prefer the canonical name; fall back to the English title when present.
    var displayName: String { name.isEmpty ? (englishName ?? "Unknown") : name }
    enum CodingKeys: String, CodingKey {
        case id, name
        case englishName = "english_name"
    }
}
