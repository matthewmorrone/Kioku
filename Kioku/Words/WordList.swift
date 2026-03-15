import Foundation

// Represents a user-created word list used to group saved vocabulary in the Words tab.
struct WordList: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
}
