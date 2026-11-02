import Foundation

// One piece of content sent to Kioku from another app's share sheet. Exactly one of `text` and
// `url` is set: shared text becomes a note as it is, a shared link is fetched and turned into a
// note by the app the next time it opens. Pure data, compiled into the app and the share extension.
nonisolated struct SharedInboxItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var text: String?
    var url: String?
    var createdAt: Date

    init(id: UUID = UUID(), title: String = "", text: String? = nil, url: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.url = url
        self.createdAt = createdAt
    }
}
