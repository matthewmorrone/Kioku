import Foundation

// What one Spotlight result says, independent of CoreSpotlight so the diffing and text-building
// logic can be tested. Pure data.
nonisolated struct SpotlightDocument: Equatable, Sendable {
    let identifier: SpotlightIdentifier
    let title: String
    let summary: String
    let keywords: [String]
    // Searchable body text, beyond what the result row shows.
    let bodyText: String?
    let modifiedAt: Date?
}
