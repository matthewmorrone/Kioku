import Foundation

// One subtitle file from Jimaku's `/entries/:id/files` response (only the fields JimakuProvider uses).
struct JimakuProviderFileEntry: Decodable {
    let url: String
    let name: String
    let size: Int
}
