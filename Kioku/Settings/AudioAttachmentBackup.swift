import Foundation

// Serializable snapshot of one audio attachment for inclusion in a full-app backup.
// Carries the UUID that links the attachment to its Note, the raw audio bytes, optional
// SRT text, and the decoded cue list so playback works immediately after restore.
struct AudioAttachmentBackup: Codable, Equatable {
    // UUID matching Note.audioAttachmentID.
    var attachmentID: UUID
    // Original audio filename (e.g. "song.mp3") — used to reconstruct the stored filename.
    var audioFilename: String
    // Raw audio file bytes, base64-encoded by JSONEncoder automatically via Data.
    var audioData: Data
    // Raw SRT text — nil when no subtitle file exists for this attachment.
    var srtText: String?
    // Decoded subtitle cues — nil when no cues have been generated.
    var cues: [SubtitleCue]?
}
