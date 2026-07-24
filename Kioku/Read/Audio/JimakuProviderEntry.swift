import Foundation

// One matched show from Jimaku's `/entries/search` response (only the fields JimakuProvider uses).
struct JimakuProviderEntry: Decodable {
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
