import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var tokenRanges: [TokenRange]?

    // Creates a note value with optional defaults for new-note workflows.
    init(id: UUID = UUID(), title: String = "", content: String = "", tokenRanges: [TokenRange]? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.tokenRanges = tokenRanges
    }
}
