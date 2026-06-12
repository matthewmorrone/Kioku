import Foundation

// Removes files owned by a note attachment when no surviving note references them.
@MainActor
protocol NotesAttachmentDeleting: AnyObject {
    // Deletes every persisted file and cache entry associated with one attachment identifier.
    func deleteAttachment(_ attachmentID: UUID)
}
