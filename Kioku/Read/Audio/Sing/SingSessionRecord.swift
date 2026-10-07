import Foundation

// One finished Sing session for a song note, as the history keeps it: when, what was practised,
// how strictly, and how it went. Missed words are kept as written in the note, for the summary.
nonisolated struct SingSessionRecord: Codable, Equatable {
    var noteID: UUID
    var date: Date
    var scope: String
    var strictness: SingStrictness
    var heardCount: Int
    var gradedCount: Int
    var missedSurfaces: [String]
}
