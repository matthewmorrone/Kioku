import Foundation

// Enforces identity, relationship, metric, and span invariants before restore
// is allowed to mutate any persisted store.
nonisolated enum AppBackupValidator {
    // Rejects a payload at the first structural inconsistency.
    static func validate(_ payload: AppBackupPayload) throws {
        try requireUnique(payload.notes.map(\.id), label: "note identifiers")
        try requireUnique(payload.words.map(\.canonicalEntryID), label: "saved-word identifiers")
        try requireUnique(payload.wordLists.map(\.id), label: "word-list identifiers")
        try requireUnique(payload.history.map(\.id), label: "history identifiers")
        try requireUnique(payload.reviewStats.map(\.canonicalEntryID), label: "review identifiers")
        try requireUnique(payload.audioAttachments.map(\.attachmentID), label: "audio identifiers")

        guard payload.lifetimeCorrect >= 0, payload.lifetimeAgain >= 0 else {
            throw AppBackupValidationError.invalid("lifetime review counters cannot be negative.")
        }
        for record in payload.reviewStats {
            guard record.correctCount >= 0, record.incorrectCount >= 0 else {
                throw AppBackupValidationError.invalid("review counters cannot be negative.")
            }
        }

        let noteIDs = Set(payload.notes.map(\.id))
        let listIDs = Set(payload.wordLists.map(\.id))
        for word in payload.words {
            guard Set(word.sourceNoteIDs).isSubset(of: noteIDs) else {
                throw AppBackupValidationError.invalid("a saved word references a missing note.")
            }
            guard Set(word.wordListIDs).isSubset(of: listIDs) else {
                throw AppBackupValidationError.invalid("a saved word references a missing word list.")
            }
        }

        let referencedAudioIDs = Set(payload.notes.compactMap(\.audioAttachmentID))
        for attachment in payload.audioAttachments where referencedAudioIDs.contains(attachment.attachmentID) == false {
            throw AppBackupValidationError.invalid("an audio attachment is not referenced by any note.")
        }

        for note in payload.notes {
            try validateSegments(note.segments, content: note.content)
        }
    }

    // Verifies exact text coverage and valid half-open UTF-16 annotation ranges.
    private static func validateSegments(_ segments: [SegmentRange]?, content: String) throws {
        guard let segments else { return }
        guard segments.map(\.surface).joined() == content else {
            throw AppBackupValidationError.invalid("persisted segments do not exactly cover their note text.")
        }

        for segment in segments {
            guard segment.surface.isEmpty == false else {
                throw AppBackupValidationError.invalid("persisted segments cannot be empty.")
            }
            let utf16Length = segment.surface.utf16.count
            var previousEnd = 0
            for annotation in segment.furigana ?? [] {
                guard annotation.start >= previousEnd,
                      annotation.end > annotation.start,
                      annotation.end <= utf16Length,
                      annotation.reading.isEmpty == false else {
                    throw AppBackupValidationError.invalid("a furigana range is invalid or overlapping.")
                }
                previousEnd = annotation.end
            }
        }
    }

    // Ensures a backup collection can be indexed without duplicate-key traps.
    private static func requireUnique<Value: Hashable>(_ values: [Value], label: String) throws {
        guard Set(values).count == values.count else {
            throw AppBackupValidationError.invalid("duplicate \(label) were found.")
        }
    }
}
