import Foundation

// The minimal CoreSpotlight work needed to bring the index in line with the app's current notes
// and words: documents to (re)index and identifiers to remove. Keeping this a pure diff means a
// one-letter note edit reindexes one note, not the library.
nonisolated struct SpotlightIndexPlan: Equatable {
    var upserts: [SpotlightDocument]
    var removals: [SpotlightIdentifier]

    var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }

    // Compares `documents` against what was last indexed (`previous`, identifier → document).
    // Only identifiers within `domains` are candidates for removal, so syncing notes cannot remove
    // words and vice versa.
    static func make(
        previous: [SpotlightIdentifier: SpotlightDocument],
        documents: [SpotlightDocument],
        domains: Set<String>
    ) -> SpotlightIndexPlan {
        var current: [SpotlightIdentifier: SpotlightDocument] = [:]
        for document in documents { current[document.identifier] = document }
        let upserts = documents.filter { previous[$0.identifier] != $0 }
        let removals = previous.keys
            .filter { domains.contains($0.domain) && current[$0] == nil }
            .sorted { $0.rawValue < $1.rawValue }
        return SpotlightIndexPlan(upserts: upserts, removals: removals)
    }
}
